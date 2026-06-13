//
// GridReconciler.swift
// GridServer
//
// Event-driven reconciler: subscribes to EventRouter, updates GridState,
// and syncs borders via SimpleBorderManager.
//

import Foundation
import CoreGraphics
import AppKit

struct PendingLaunchTarget {
    let spaceID: String
    let cellID: String
    let createdAt: CFAbsoluteTime
    // Bundle id of the picked app, used to match the launched window before the
    // PID arrives (#31). nil for non-app launches (e.g. directory/tmux).
    var bundleID: String?
    // PID of the launched app; nil until NSWorkspace completion fires
    var pid: pid_t?
}

class GridReconciler: StateEventHandler {

    // Dependencies (set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateProvider: (any StateProvider)?
    private weak var borderRenderer: (any BorderRendering)?

    // Weak references to GridApply and GridFocus for picker-launched window handling
    private weak var gridApply: GridApply?
    private weak var gridFocus: GridFocus?
    private weak var windowController: (any WindowController)?

    // Strong reference to StateValidator — GridReconciler is the owning reference
    // that keeps the validator (and its periodic timer) alive for process lifetime
    private var stateValidator: StateValidator?

    // Focus sweep: periodic timer that compares OS focus against GridState
    // and corrects drift from late/stale events.
    private var sweepTimer: DispatchSourceTimer?
    private let sweepInterval: TimeInterval = 0.3

    // Guards user commands during sleep/wake recovery.
    // Non-nil only while handleSystemWake is in progress.
    // Commands call awaitWakeCompletion() to wait for this to finish.
    private var wakeValidationTask: Task<Void, Never>? = nil

    // One-shot target: next tileable window created on target space claims this cell
    private var pendingLaunchTarget: PendingLaunchTarget?

    // #41: windows that classified as not_standard (e.g. AXStandardWindow with no
    // fullscreen button) at creation, tracked with the timestamp first seen.
    // A later sweep re-classifies them within a grace window — apps that populate
    // window buttons slightly after creation then tile without a manual reopen.
    private var notStandardGrace: [UInt32: CFAbsoluteTime] = [:]

    // FIX 1 / DW-D2: windows deliberately moved across spaces, with the move
    // timestamp. On a machine where MSS is unavailable the SLS space query
    // (wmState.windows[wid].spaces) lags the async move by up to a poll
    // interval (~3s), so sweepDisplacedWindows would otherwise see the
    // just-moved window as "displaced" and migrate its GridState assignment
    // back — bouncing the move. A window within this grace is exempt from
    // displaced-sweep correction until SLS catches up. Lives on the
    // single-threaded reconciler event path (same threading class as
    // notStandardGrace) — no new shared concurrency state.
    private var crossMoveGrace: [UInt32: CFAbsoluteTime] = [:]

    // Grace span for crossMoveGrace. 5s covers the ~3s SLS poll lag with
    // margin (matches the fence-timeout magnitude).
    private let crossMoveGraceSeconds: CFAbsoluteTime = 5.0

    // Timeout for pending launch target (app may take time to launch)
    private let pendingLaunchTimeout: CFAbsoluteTime = 15.0

    // Ref-counted suppression for bulk operations (layout apply, picker, terminal, focus).
    // Managed exclusively via executeAction/beginAction/endAction -- no direct access.
    // Multiple callers can nest suppress/unsuppress without interfering.
    private var suppressionDepth: Int = 0
    private var suppressReconciliation: Bool { suppressionDepth > 0 }

    // Per-window fencing: OS focus events for fenced windows are dropped
    // until released or expired. Replaces the old move cooldown model.
    // Refcounted (DW-1.3, #14): overlapping moves of the same window each
    // acquire; the entry is removed only when the refcount returns to zero, so
    // one move releasing does not strip another in-flight move's fence.
    private var fence = RefcountedFence(timeout: 5.0)

    // Monotonic generation counter (DW-1.7): bumped on each action entry so
    // handlers / the focus sweep can detect a stale pre-await snapshot.
    // Primitive consumed by later phases (P2/P3).
    private var generationCounter = GenerationCounter()

    // Current action generation. A handler snapshots this before an await and
    // re-reads it afterward; a change means an action ran in between.
    var generation: UInt64 { generationCounter.current }

    // Events (windowCreated/windowDestroyed) that arrived while suppressed are
    // queued here (DW-1.6, #12) instead of being dropped, then replayed in
    // arrival order when suppressionDepth returns to 0.
    private var suppressedEvents = SuppressedEventQueue()

    // Lock-state tracking (DW-2.5, #23). The reconciler is the single
    // serialized consumer of screenLocked/screenUnlocked/systemWoke events, so
    // a plain Bool is sufficient (no new actor; §8 satisfied). On wake the
    // validator is resumed ONLY when the screen is not locked — resuming at the
    // login screen lets AX's reduced window list false-positive ax_orphan
    // prunes against real tiled windows.
    private var screenLocked: Bool = false

    // _test_setScreenLocked: drive the lock flag directly in tests.
    func _test_setScreenLocked(_ locked: Bool) {
        screenLocked = locked
    }

    // Consume-once action tokens (DW-1.4, #4). A long-lived session token is
    // minted by beginAction and consumed exactly once by endAction; a second
    // endAction for the same token (e.g. a racing @nudge exit) is rejected and
    // does NOT decrement another session's suppression.
    private var actionTokens = ActionTokenRegistry()

    init() {}

    // MARK: - Public API

    // Opaque token returned by beginAction, consumed by endAction.
    // Carries a unique id so endAction can consume it exactly once.
    struct ActionToken {
        let id: UInt64
        let label: String
        let startTime: CFAbsoluteTime
    }

    // executeAction: unified lifecycle wrapper for short-lived state-mutating actions.
    //
    // Lifecycle: suppress -> execute closure -> sync borders -> unsuppress
    //
    // Parameters:
    //   label: string for logging (e.g. "focus.left", "layout.apply")
    //   syncBorders: whether to sync borders on completion (default: true).
    //     Callers that do their own border sync inside the closure pass false.
    //   body: async throwing closure containing the action's work
    //
    // Error handling: if body throws, still unsuppress and sync (borders should reflect
    // whatever partial state change happened).
    func executeAction<T>(
        label: String,
        syncBorders: Bool = true,
        body: () async throws -> T
    ) async rethrows -> T {
        jlog("action.start", data: ["label": label])

        // 1. Suppress reconciler + bump the action generation (DW-1.7)
        suppressionDepth += 1
        generationCounter.bump()

        // 2. Execute the caller's work
        do {
            let result = try await body()

            // 3. Unsuppress
            suppressionDepth = max(0, suppressionDepth - 1)

            // 4. At depth 0: replay any events queued during suppression (DW-1.6),
            //    then sweep + sync borders. Replay drains BEFORE border sync so the
            //    newly-adopted/removed windows are reflected.
            if suppressionDepth == 0 {
                await replaySuppressedEvents()
                if syncBorders {
                    await sweepDisplacedWindows()
                    await syncBordersForCurrentSpace()
                }
            }

            jlog("action.end", data: ["label": label])
            return result

        } catch {
            // Still unsuppress on error — and still drain the suppressed queue so a
            // throwing body does not strand queued create/destroy events.
            suppressionDepth = max(0, suppressionDepth - 1)

            if suppressionDepth == 0 {
                await replaySuppressedEvents()
                if syncBorders {
                    await sweepDisplacedWindows()
                    await syncBordersForCurrentSpace()
                }
            }

            jlog("action.err", data: ["label": label, "err": "\(error)"])
            throw error
        }
    }

    // beginAction: start a long-lived suppression session.
    // Returns an ActionToken that must be passed to endAction when the session ends.
    // Used by nudge mode where suppression spans multiple keystrokes.
    func beginAction(label: String) -> ActionToken {
        suppressionDepth += 1
        generationCounter.bump()
        let consumable = actionTokens.begin(label: label)
        jlog("action.begin", data: ["label": label, "depth": suppressionDepth])
        return ActionToken(id: consumable.id, label: label, startTime: consumable.startTime)
    }

    // endAction: end a long-lived suppression session started by beginAction.
    // Decrements suppression and optionally syncs borders when depth reaches 0.
    // Consume-once (DW-1.4, #4): a token already consumed by an earlier endAction
    // is rejected here, so a racing duplicate exit cannot strip another session's
    // suppression.
    func endAction(_ token: ActionToken, syncBorders: Bool = true) {
        guard actionTokens.consume(id: token.id) else {
            jlog("warn.action.end.consumed", data: ["label": token.label])
            return
        }
        if suppressionDepth <= 0 {
            jlog("warn.action.end.underflow", data: ["label": token.label])
        }
        suppressionDepth = max(0, suppressionDepth - 1)
        jlog("action.end", data: [
            "label": token.label,
            "depth": suppressionDepth,
            "dur_ms": Int((CFAbsoluteTimeGetCurrent() - token.startTime) * 1000),
        ])
        if suppressionDepth == 0 {
            Task { [weak self] in
                guard let self else { return }
                await self.replaySuppressedEvents()
                if syncBorders {
                    await self.sweepDisplacedWindows()
                    await self.syncBordersForCurrentSpace()
                }
            }
        }
    }

    // Replay events queued while suppressed (DW-1.6, #12). Drains the queue in
    // arrival order and dispatches each create/destroy to its handler. Replaying
    // an already-gone wid is idempotent (handlers tolerate untracked windows).
    private func replaySuppressedEvents() async {
        let drained = suppressedEvents.drain()
        for entry in drained {
            switch entry.event {
            case .windowCreated(let wid):
                jlog("reconcile.suppressed.replay", data: [
                    "event": "windowCreated", "wid": Int(wid), "gen": Int(entry.generation),
                ])
                await handleWindowCreated(wid, nil)
            case .windowDestroyed(let wid):
                jlog("reconcile.suppressed.replay", data: [
                    "event": "windowDestroyed", "wid": Int(wid), "gen": Int(entry.generation),
                ])
                await handleWindowDestroyed(wid)
            }
        }
        // DW-4.8 (#12): even after replay, a windowCreated dropped during
        // suppression can leave a tileable window that StateManager knows about
        // but GridState never tiled (the create was never queued because it
        // arrived before suppression started, or its replay bailed). Adopt those
        // at depth 0 so no tileable window is silently left untracked.
        await adoptUntrackedTileables()
    }

    // Scan StateManager windows for tileables absent from every GridState cell
    // and adopt them (DW-4.8 / #12). Runs only at suppressionDepth 0.
    func adoptUntrackedTileables() async {
        guard suppressionDepth == 0 else { return }
        guard let gridState, let stateProvider else { return }

        let wmState = await stateProvider.getState()
        let trackedWids = Set(await gridState.getAllWindowIDs())

        for (widStr, windowState) in wmState.windows {
            guard let wid = UInt32(widStr) else { continue }
            var assignedAnywhere = trackedWids.contains(wid)
            if !assignedAnywhere {
                assignedAnywhere = await gridState.isWindowRejected(wid)
            }
            guard AdoptionPolicy.isUntrackedTileable(
                isTileable: isTileable(window: windowState),
                isAssignedAnywhere: assignedAnywhere
            ) else { continue }

            jlog("validate.win.untracked", data: [
                "wid": Int(wid),
                "app": windowState.appName ?? "unknown",
            ])
            await handleWindowCreated(wid, windowState.pid)
        }
    }

    // Fence one or more windows so OS focus events for them are dropped.
    // Called by move commands before they begin mutating state.
    // reason: logging context only (not stored).
    func acquireFence(windowIDs: Set<UInt32>, reason: String) {
        guard !windowIDs.isEmpty else {
            jlog("warn.fence.empty", msg: "acquireFence called with empty set")
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        for windowID in windowIDs.sorted() {
            let depth = fence.acquire(windowID, now: now)
            jlog("fence.acquire", data: [
                "wid": Int(windowID),
                "depth": depth,
                "reason": reason,
            ])
        }
    }

    // Release fence for specific windows. Called after border sync completes.
    // Refcounted: the window stays fenced until every overlapping acquire has
    // released (depth 0). Releasing an unheld window is a logged no-op.
    func releaseFence(windowIDs: Set<UInt32>) {
        for windowID in windowIDs.sorted() {
            let depth = fence.release(windowID)
            jlog("fence.release", data: [
                "wid": Int(windowID),
                "depth": depth,
            ])
        }
    }

    // FIX 1 / DW-D2: record a deliberate cross-space move so the displaced
    // sweep exempts this window until the SLS space query catches up. Called
    // synchronously from GridWindowMove.moveWindowCrossDisplay after the move
    // succeeds (mirrors acquireFence — single-threaded reconciler path).
    func noteCrossSpaceMove(_ windowID: UInt32) {
        crossMoveGrace[windowID] = CFAbsoluteTimeGetCurrent()
    }

    func setPendingLaunchTarget(_ target: PendingLaunchTarget?) {
        pendingLaunchTarget = target
        if let target {
            jlog("reconcile.pending.set", data: ["spaceID": target.spaceID, "cellID": target.cellID])
        }
    }

    // Clear an armed pending target after a failed launch (#31). Without this a
    // silently-failed picker launch (uninstalled / stale app) leaves the target
    // armed for the full 15s timeout, guaranteed to hijack the next unrelated
    // window the user opens.
    func clearPendingLaunchTarget(reason: String) {
        guard pendingLaunchTarget != nil else { return }
        pendingLaunchTarget = nil
        jlog("warn.pick.launch_fail", data: ["reason": reason])
    }

    // Update the PID on the live pending target once NSWorkspace fires its completion.
    // No-op if the target was already consumed (nil) by the time PID arrives.
    func updatePendingLaunchTargetPID(_ pid: pid_t) {
        guard pendingLaunchTarget != nil else { return }
        pendingLaunchTarget?.pid = pid
        jlog("reconcile.pending.pid", data: ["pid": pid])
    }

    func setApply(_ apply: GridApply) {
        self.gridApply = apply
    }

    func setFocus(_ focus: GridFocus) {
        self.gridFocus = focus
    }

    func setWindowController(_ controller: any WindowController) {
        self.windowController = controller
    }

    func setValidator(_ validator: StateValidator) {
        self.stateValidator = validator
    }

    // awaitWakeCompletion
    //
    // Called by GridCommandRouter before processing any command.
    // If wake validation is in progress, suspends the caller until it finishes.
    // Fast path (common case): wakeValidationTask is nil, returns immediately.
    func awaitWakeCompletion() async {
        await wakeValidationTask?.value
    }

    // Check if a window is currently fenced (not expired).
    // Lazily cleans up expired entries.
    private func isWindowFenced(_ windowID: UInt32) -> Bool {
        fence.isFenced(windowID)
    }

    // isCellMateOfFencedWindow: returns true if windowID shares a cell (in any
    // space) with at least one currently-active fenced window.
    // Called only after isWindowFenced returns false, so windowID itself is not
    // fenced. Uses RefcountedFence.activeWindows for the non-expired set.
    // Returns false immediately when no window is fenced (the common case).
    private func isCellMateOfFencedWindow(_ windowID: UInt32) async -> Bool {
        guard let gridState else { return false }

        // Collect active (non-expired) fenced window IDs.
        let activeFencedIDs = fence.activeWindows()

        // Fast path: no active fences (normal operation outside of moves).
        if activeFencedIDs.isEmpty { return false }

        // For each space, check whether windowID and any fenced window share a cell.
        let spaceIDs = await gridState.getSpaceIDs()

        for spaceID in spaceIDs {
            guard let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID) else {
                continue
            }

            let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)

            for cellWID in cellWindows where activeFencedIDs.contains(cellWID) {
                return true
            }
        }

        return false
    }

    // Store references, register with EventRouter
    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateProvider: any StateProvider,
        borderRenderer: any BorderRendering
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateProvider = stateProvider
        self.borderRenderer = borderRenderer

        Task {
            await EventRouter.shared.register(self)
        }

        startSweepTimer()
        jlog("reconcile.init")
    }

    // MARK: - Focus Sweep

    // Start the periodic focus sweep timer.
    // Fires every 300ms on a utility queue; the actual work hops to the
    // reconciler's context via Task.
    private func startSweepTimer() {
        let queue = DispatchQueue(label: "com.thegrid.focussweep", qos: .userInteractive)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + sweepInterval,
            repeating: sweepInterval,
            leeway: .milliseconds(50)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.focusSweep()
                await self.rejectedWindowSweep()
                await self.notStandardGraceSweep()
            }
        }
        sweepTimer = source
        source.resume()
        jlog("sweep.timer.start", data: ["intervalMs": Int(sweepInterval * 1000)])
    }

    // Compare OS-level focused window against GridState focus.
    // If they diverge, correct GridState and sync borders.
    private func focusSweep() async {
        // Skip during suppressed actions — the action owns focus
        guard !suppressReconciliation else { return }
        guard let gridState, let stateProvider else { return }

        // #13: snapshot the action generation BEFORE the awaits below. If an
        // action begins while the sweep is suspended, this changes and the
        // sweep's read is stale — bail before writing a reverted focus.
        let genAtStart = generation

        let wmState = await stateProvider.getState()
        guard let osWindowID = wmState.metadata.focusedWindowID, osWindowID != 0 else { return }

        // Resolve which display/space the OS-focused window is on
        guard let spaceID = await gridState.findSpaceContaining(windowID: osWindowID) else { return }

        // Compare against GridState's focused window for that space
        let gridFocusedWID = await gridState.getFocusedWindow(spaceID: spaceID)
        guard gridFocusedWID != osWindowID else { return }

        // Mismatch — correct GridState
        let cellID = await gridState.getWindowCell(windowID: osWindowID, inSpace: spaceID)
        guard let cellID else { return }

        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        let windowIndex = cellWindows.firstIndex(of: osWindowID) ?? 0

        // #13: re-check the guard immediately before the write. Skip if a move
        // fenced this window (or a cell-mate), if an action began mid-sweep
        // (generation changed), or if suppression turned on. Without this the
        // sweep reverts focus to the pre-move window ~0-300ms after a command.
        let osWindowFenced = isWindowFenced(osWindowID)
        let cellMateFenced = osWindowFenced ? false : await isCellMateOfFencedWindow(osWindowID)
        guard shouldSweepCorrect(
            osWindowFenced: osWindowFenced,
            cellMateFenced: cellMateFenced,
            genAtStart: genAtStart,
            genNow: generation,
            suppressed: suppressReconciliation
        ) else {
            jlog("sweep.skip", data: [
                "osWid": osWindowID,
                "fenced": osWindowFenced || cellMateFenced,
                "genChanged": genAtStart != generation,
            ])
            return
        }

        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)

        // Find display for this space and sync borders
        let displayUUID = findDisplayUUIDForSpace(spaceID, from: wmState)
            ?? findCurrentDisplayUUID(from: wmState)
        guard let displayUUID else { return }

        await borderRenderer?.updateFocus(
            newFocusedWindow: osWindowID,
            displayUUID: displayUUID
        )
        await syncBordersForSpace(spaceID, displayUUID: displayUUID)

        jlog("sweep.correct", data: [
            "osWid": osWindowID,
            "gridWid": gridFocusedWID,
            "cell": cellID,
            "space": spaceID,
        ])
    }

    // Re-check rejected windows that may now be tileable.
    // Catches apps (Chrome, Ghostty) that create phantom 0x0 windows at launch
    // then fill in real dimensions without firing AX move/resize notifications.
    private func rejectedWindowSweep() async {
        guard !suppressReconciliation else { return }
        guard let gridState, let stateProvider else { return }

        let rejected = await gridState.getRejectedWindows()
        guard !rejected.isEmpty else { return }

        let wmState = await stateProvider.getState()

        for wid in rejected {
            guard let windowState = wmState.windows[String(wid)] else { continue }
            guard isTileable(window: windowState) else { continue }

            await gridState.unrejectWindow(wid)
            jlog("sweep.unrejected", data: [
                "wid": wid,
                "w": windowState.frame.width,
                "h": windowState.frame.height,
            ])

            if pendingLaunchTarget != nil {
                await handlePendingLaunchWindow(wid, windowState.pid)
            } else {
                await handleWindowCreated(wid, windowState.pid)
            }
        }
    }

    // #41: re-evaluate windows that classified as not_standard at creation.
    // Within the grace window, re-run handleWindowCreated (which re-classifies
    // against the now-populated AX state) so a slow-button window tiles without
    // a manual reopen. Past the grace window, drop the entry and give up.
    func notStandardGraceSweep() async {
        guard !suppressReconciliation else { return }
        guard !notStandardGrace.isEmpty else { return }
        guard let stateProvider else { return }

        let wmState = await stateProvider.getState()
        let now = CFAbsoluteTimeGetCurrent()
        // Snapshot keys so re-classification can mutate the map underneath us.
        for (wid, firstSeen) in notStandardGrace {
            if !NotStandardGracePolicy.shouldReevaluate(now: now, firstSeen: firstSeen) {
                notStandardGrace[wid] = nil
                jlog("reconcile.not_standard.expired", data: ["wid": Int(wid)])
                continue
            }
            guard let windowState = wmState.windows[String(wid)] else {
                // Window gone — drop the grace entry.
                notStandardGrace[wid] = nil
                continue
            }
            let appName = windowState.appName ?? ""
            let category = classifyWindow(window: windowState, appName: appName)
            guard category == .standard else { continue }
            // Now standard — clear the entry and route through the create path.
            notStandardGrace[wid] = nil
            jlog("reconcile.not_standard.reeval", data: ["wid": Int(wid), "app": appName])
            await handleWindowCreated(wid, windowState.pid)
        }
    }

    // MARK: - StateEventHandler

    func handle(_ event: StateEvent, context: EventContext) async throws {
        // Focus events handle suppression/fencing internally
        if case .focusChanged(let focusState) = event {
            await handleFocusChanged(focusState)
            return
        }

        // Check pending launch target for windowCreated BEFORE suppression guard.
        // Picker-launched windows must be claimed even during move suppression.
        if case .windowCreated(let windowID, let pid) = event {
            if pendingLaunchTarget != nil {
                await handlePendingLaunchWindow(windowID, pid)
                return
            }
        }

        // Space ID reassignment must always be processed — it affects GridState
        // integrity and cannot wait for suppression to end.
        if case .spaceIDReassigned(let oldSpaceID, let newSpaceID, let displayUUID) = event {
            await handleSpaceIDReassigned(
                oldSpaceID: oldSpaceID,
                newSpaceID: newSpaceID,
                displayUUID: displayUUID
            )
            return
        }

        // Queue (don't drop) window create/destroy that arrive during suppression
        // (DW-1.6, #12). They are replayed in arrival order when depth returns to 0.
        // Other events (move/resize/minimize/etc.) are still skipped — the active
        // action owns those and a fresh sweep reconciles them afterward.
        if suppressReconciliation {
            switch event {
            case .windowCreated(let windowID, _):
                suppressedEvents.enqueue(.windowCreated(wid: windowID), generation: generation)
                jlog("reconcile.suppressed.queue", data: [
                    "event": "windowCreated", "wid": Int(windowID), "gen": Int(generation),
                ])
            case .windowDestroyed(let windowID):
                suppressedEvents.enqueue(.windowDestroyed(wid: windowID), generation: generation)
                jlog("reconcile.suppressed.queue", data: [
                    "event": "windowDestroyed", "wid": Int(windowID), "gen": Int(generation),
                ])
            default:
                break
            }
            return
        }

        switch event {
        case .windowDestroyed(let windowID):
            await handleWindowDestroyed(windowID)

        case .windowCreated(let windowID, let pid):
            await handleWindowCreated(windowID, pid)

        case .systemWoke:
            await handleSystemWake()

        case .systemWillSleep:
            await stateValidator?.pause()

        case .screenLocked:
            screenLocked = true
            await stateValidator?.pause()

        case .screenUnlocked:
            screenLocked = false
            await stateValidator?.resume()

        case .spaceActivated(let spaceID, let displayUUID):
            await handleSpaceActivated(spaceID: spaceID, displayUUID: displayUUID)

        case .displayGeometryChanged(let displayUUID):
            await handleDisplayGeometryChanged(displayUUID)

        case .windowMoved(let windowID, let frame):
            await handleWindowMoved(windowID, frame)

        case .windowResized(let windowID, let frame):
            await handleWindowMoved(windowID, frame)

        case .windowMinimized(let windowID):
            await handleWindowMinimized(windowID)

        case .windowDeminimized(let windowID):
            await handleWindowDeminimized(windowID)

        case .displayConnected(let displayUUID):
            await handleDisplayConnected(displayUUID)

        case .displayDisconnected(let displayUUID):
            await handleDisplayDisconnected(displayUUID)

        case .appTerminated(let app):
            await handleAppTerminated(app)

        default:
            // Ignore other events (app lifecycle, title changes, etc.)
            break
        }
    }

    // MARK: - Event Handlers

    // handleAppTerminated: instrumentation-only scan over gridState cells.
    // When an app dies we want to tell, post-mortem, whether the crash was
    // correlated with cells still referencing wids owned by the dying pid.
    // Does NOT mutate state — the per-window AX destroy flow still runs.
    private func handleAppTerminated(_ app: NSRunningApplication) async {
        guard let gridState, let stateProvider else { return }
        let pid = app.processIdentifier

        // Collect the per-space assignments snapshot from GridState.
        let spaceIDs = await gridState.getSpaceIDs()
        var assignmentsBySpace: [String: [String: [UInt32]]] = [:]
        for spaceID in spaceIDs {
            assignmentsBySpace[spaceID] = await gridState.getWindowAssignments(spaceID: spaceID)
        }

        // Build space→display map from wmState.
        let wmState = await stateProvider.getState()
        var spaceToDisplay: [String: String] = [:]
        for (spaceID, space) in wmState.spaces {
            spaceToDisplay[spaceID] = space.displayUUID
        }

        let stale = AppTermReconciler.findStaleCells(
            pid: pid,
            wmState: wmState,
            assignmentsBySpace: assignmentsBySpace,
            spaceToDisplay: spaceToDisplay
        )

        let payload: [[String: Any]] = stale.map { entry in
            [
                "display": entry.display,
                "cell": entry.cell,
                "wids": entry.wids.map { Int($0) }
            ]
        }

        jlog("app.term.reconcile", data: [
            "app": app.localizedName ?? "?",
            "pid": Int(pid),
            "displays_with_stale_wids": payload
        ])
    }

    private func handleWindowDestroyed(_ windowID: UInt32) async {
        // Remove window from GridState (all spaces)
        await gridState?.removeWindowFromAllSpaces(windowID)

        // Tell border renderer to clean up borders for this window
        await borderRenderer?.handleWindowDestroyed(windowID: windowID)

        // Sync borders for current space (assignments changed)
        await syncBordersForCurrentSpace()

        jlog("reconcile.win.destroy", data: ["wid": windowID])
    }

    // pid is the creating process id when known from the live event. It is
    // currently informational only — the handler resolves everything it needs
    // from windowState — so suppressed-event replay may pass nil.
    private func handleWindowCreated(_ windowID: UInt32, _ pid: pid_t?) async {
        guard let stateProvider else {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_stateProvider"])
            return
        }
        let wmState = await stateProvider.getState()

        guard let gridState else {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_gridState"])
            return
        }

        // Get the window state from StateManager
        guard let windowState = wmState.windows[String(windowID)] else {
            jlog("reconcile.win.create.bail", data: [
                "wid": windowID,
                "reason": "not_in_state",
                "windowCount": wmState.windows.count
            ])
            return
        }

        // Resolve the space from the window's actual OS-level space assignment.
        // With multiple monitors the focused space can differ from the window's
        // display, so metadata.activeSpaceID is unreliable here.
        guard let spaceID = await resolveWindowSpace(windowState, gridState: gridState, wmState: wmState) else {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_spaceID"])
            return
        }

        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        if layoutID.isEmpty {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_layout", "space": spaceID])
            return
        }

        // Check if window is tileable
        guard isTileable(window: windowState) else {
            await gridState.rejectWindow(windowID)
            jlog("reconcile.win.create.bail", data: [
                "wid": windowID,
                "reason": "not_tileable",
                "role": windowState.role ?? "nil",
                "subrole": windowState.subrole ?? "nil",
                "w": windowState.frame.width,
                "h": windowState.frame.height
            ])
            return
        }

        // Check window classification
        let appName = windowState.appName ?? ""
        let category = classifyWindow(window: windowState, appName: appName)
        if category != .standard {
            // #41: track for grace re-evaluation rather than a terminal bail.
            // A window whose buttons populate slightly after creation reads as
            // floating here; the grace sweep re-classifies it shortly after.
            if notStandardGrace[windowID] == nil {
                notStandardGrace[windowID] = CFAbsoluteTimeGetCurrent()
            }
            jlog("reconcile.win.create.bail", data: [
                "wid": windowID,
                "reason": "not_standard",
                "category": String(describing: category),
                "grace": true,
                "app": appName
            ])
            return
        }
        // Window classified standard — clear any prior not_standard grace entry.
        notStandardGrace[windowID] = nil

        // Skip if window is already assigned (e.g., via pending launch target from poll)
        let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
        for (_, windowIDs) in assignments {
            if windowIDs.contains(windowID) {
                jlog("reconcile.win.create.skip", data: ["wid": windowID, "reason": "already_assigned"])
                return
            }
        }

        // Check locked rules: if window matches a locked app rule, assign to its reserved cell.
        // Search current space first, then all spaces (the locked cell may be on another display).
        let appRules: [GridAppRule]
        if let override = _test_appRuleOverride {
            appRules = override
        } else {
            appRules = await MainActor.run { gridConfig?.appRules ?? [] }
        }
        let bundleID = wmState.applications[String(windowState.pid)]?.bundleIdentifier
        let lockedCell = getLockedCell(
            appName: appName,
            bundleID: bundleID,
            appRules: appRules
        )

        if let lockedCell {
            // Try current space first
            if assignments[lockedCell] != nil {
                await gridState.assignWindow(windowID, toCellID: lockedCell, inSpace: spaceID)
                try? await gridApply?.applyCellLayout(spaceID: spaceID, cellID: lockedCell)
                await syncBordersForCurrentSpace()
                jlog("reconcile.win.create.locked", data: [
                    "wid": windowID,
                    "cell": lockedCell,
                    "space": spaceID,
                    "app": appName,
                ])
                return
            }

            // Current space doesn't have the locked cell — search other spaces
            let allSpaceIDs = await gridState.getSpaceIDs()
            for otherSpaceID in allSpaceIDs where otherSpaceID != spaceID {
                let otherLayout = await gridState.getCurrentLayout(spaceID: otherSpaceID)
                guard !otherLayout.isEmpty else { continue }
                let otherAssignments = await gridState.getWindowAssignments(spaceID: otherSpaceID)
                if otherAssignments[lockedCell] != nil {
                    await gridState.assignWindow(windowID, toCellID: lockedCell, inSpace: otherSpaceID)
                    let displayUUID = findDisplayUUIDForSpace(otherSpaceID, from: wmState)
                    if let displayUUID {
                        // The locked cell's space is currently visible — position now.
                        try? await gridApply?.applyCellLayout(spaceID: otherSpaceID, cellID: lockedCell)
                        await syncBordersForSpace(otherSpaceID, displayUUID: displayUUID)
                        jlog("reconcile.win.create.locked", data: [
                            "wid": windowID,
                            "cell": lockedCell,
                            "space": otherSpaceID,
                            "crossDisplay": true,
                            "app": appName,
                        ])
                    } else {
                        // #32: the locked cell's space is NOT visible on any
                        // display. Move the window to that space so the next
                        // displacement sweep does not bounce it back into the
                        // original space, defeating the locked rule. If the move
                        // fails the assignment still stands (deferred until the
                        // space becomes active).
                        var moved = false
                        if let targetSpaceNum = UInt64(otherSpaceID) {
                            moved = windowController?.moveWindowToSpace(
                                windowID: windowID, spaceID: targetSpaceNum
                            ) ?? false
                        }
                        if !moved {
                            // SLS move failed — assignment still stands (deferred)
                            // but log err.verify so the failure is observable.
                            jlog("err.verify", data: [
                                "wid": windowID,
                                "cell": lockedCell,
                                "space": otherSpaceID,
                                "reason": "moveWindowToSpace.failed",
                            ])
                        }
                        jlog("reconcile.win.create.locked", data: [
                            "wid": windowID,
                            "cell": lockedCell,
                            "space": otherSpaceID,
                            "crossDisplay": true,
                            "inactive": true,
                            "moved": moved,
                            "app": appName,
                        ])
                    }
                    return
                }
            }
        }

        // Auto-assign: prefer focused cell (if non-empty and not locked), else least-populated
        let locked = lockedCellIDs(appRules: appRules)
        let focusedCell = await gridState.getFocusedCell(spaceID: spaceID)
        let targetCell = GridReconciler.pickTargetCell(
            focusedCell: focusedCell,
            assignments: assignments,
            locked: locked
        )

        if !targetCell.isEmpty {
            await gridState.assignWindow(windowID, toCellID: targetCell, inSpace: spaceID)

            // Sync borders after assignment
            await syncBordersForCurrentSpace()
        }

        jlog("reconcile.win.create", data: ["wid": windowID, "cell": targetCell])
    }

    // Re-arm a pending target that was consume-before-await'd but then skipped.
    // Only restores when no newer target was armed during the await (a fresh
    // pick takes precedence over a stale re-arm).
    private func restorePendingTarget(_ target: PendingLaunchTarget) {
        guard pendingLaunchTarget == nil else { return }
        pendingLaunchTarget = target
    }

    private func handlePendingLaunchWindow(_ windowID: UInt32, _ pid: pid_t) async {
        // #18: consume-before-await. Snapshot the target and clear the live
        // field BEFORE the first await so two interleaved invocations (the event
        // path and the 300ms sweep) cannot both observe it non-nil and both
        // claim the same cell. Skip paths re-arm via restorePendingTarget so a
        // later real window can still claim it.
        guard let target = pendingLaunchTarget else {
            // No target (race condition safety) -- fall through
            await handleWindowCreated(windowID, pid)
            return
        }
        pendingLaunchTarget = nil

        // Timeout -- target is stale; drop it and fall through (unrecoverable).
        let elapsed = CFAbsoluteTimeGetCurrent() - target.createdAt
        if elapsed > pendingLaunchTimeout {
            jlog("reconcile.pending.expired", data: ["elapsed": elapsed])
            await handleWindowCreated(windowID, pid)
            return
        }

        // Get window state from StateManager (first await — target already consumed).
        guard let stateProvider else {
            restorePendingTarget(target)
            return
        }
        let wmState = await stateProvider.getState()
        guard let windowState = wmState.windows[String(windowID)] else {
            // Window not in state yet -- re-arm and let a later event retry.
            restorePendingTarget(target)
            jlog("reconcile.pending.skip", data: ["wid": windowID, "reason": "not_in_state"])
            return
        }

        // #31: match the launched window to the picked app. A pid-less target
        // (NSWorkspace completion not yet fired) requires a bundle-id match; once
        // the PID is known it is authoritative. A foreign window may not claim a
        // pid-less target — re-arm and route it to ordinary auto-assign.
        let windowBundleID = wmState.applications[String(windowState.pid)]?.bundleIdentifier
        if !PendingLaunchPolicy.matchesTarget(
            windowBundleID: windowBundleID,
            targetBundleID: target.bundleID,
            windowPID: windowState.pid,
            targetPID: target.pid
        ) {
            restorePendingTarget(target)
            jlog("reconcile.pending.skip", data: [
                "wid": windowID,
                "reason": "no_match",
                "gotBundle": windowBundleID ?? "nil",
                "wantBundle": target.bundleID ?? "nil",
                "gotPid": pid,
                "wantPid": target.pid ?? 0,
            ])
            await handleWindowCreated(windowID, pid)
            return
        }

        // Re-arm and skip (don't consume) if window is a phantom: non-tileable.
        if !isTileable(window: windowState) {
            restorePendingTarget(target)
            jlog("reconcile.pending.skip", data: [
                "wid": windowID,
                "reason": "not_tileable",
                "w": windowState.frame.width,
                "h": windowState.frame.height,
            ])
            await handleWindowCreated(windowID, pid)
            return
        }

        // Re-arm and skip if window is modal — modal dialogs are transient and
        // should not consume the pending target.
        // Accept floating-classified windows (e.g. System Settings lacks a
        // fullscreen button) since the user explicitly chose this app via picker.
        if windowState.isModal {
            restorePendingTarget(target)
            jlog("reconcile.pending.skip", data: [
                "wid": windowID,
                "reason": "modal",
            ])
            await handleWindowCreated(windowID, pid)
            return
        }

        // Window appeared on the wrong space — try to move it to the target space.
        let actualSpaceID = windowState.spaces.first.map { String($0) }
            ?? findCurrentSpaceID(from: wmState)
        if actualSpaceID == nil || actualSpaceID != target.spaceID {
            guard let targetSpaceNum = UInt64(target.spaceID) else {
                await handleWindowCreated(windowID, pid)
                return
            }
            let moved = windowController?.moveWindowToSpace(windowID: windowID, spaceID: targetSpaceNum) ?? false
            if !moved {
                jlog("reconcile.pending.space.mismatch", data: [
                    "expected": target.spaceID,
                    "actual": actualSpaceID ?? "nil",
                    "move": "failed",
                ])
                await handleWindowCreated(windowID, pid)
                return
            }
            jlog("reconcile.pending.space.moved", data: [
                "expected": target.spaceID,
                "actual": actualSpaceID ?? "nil",
                "wid": windowID,
            ])
        }

        // Target space lost its layout (unrecoverable) -- target stays consumed.
        guard let gridState else { return }
        let layoutID = await gridState.getCurrentLayout(spaceID: target.spaceID)
        if layoutID.isEmpty {
            await handleWindowCreated(windowID, pid)
            return
        }

        // All checks passed: target already consumed -- assign window to the cell.
        await gridState.prependWindow(windowID, toCellID: target.cellID, inSpace: target.spaceID)
        await gridState.setFocus(spaceID: target.spaceID, cellID: target.cellID, windowIndex: 0)

        // Apply layout to position all windows in the cell
        try? await gridApply?.applyCellLayout(spaceID: target.spaceID, cellID: target.cellID)

        // Focus the new window via accessibility
        _ = try? await gridFocus?.focusWindowByID(windowID)

        // Sync borders to reflect new assignment
        await syncBordersForCurrentSpace()

        jlog("reconcile.win.create.picker", data: ["wid": windowID, "cell": target.cellID])
    }

    private func handleFocusChanged(_ focusState: FocusState) async {
        guard let gridState, let stateProvider, let windowID = focusState.windowID else { return }

        // During suppression (bulk ops: layout apply, picker, terminal, focus),
        // skip entirely -- the caller sets GridState focus explicitly.
        if suppressReconciliation {
            jlog("reconcile.focus.suppressed", data: ["wid": windowID])
            return
        }

        // Check fence: if this window is fenced, drop the OS event.
        // Fences are per-window: other windows' events pass through normally.
        if isWindowFenced(windowID) {
            jlog("reconcile.focus.fenced", data: ["wid": windowID])
            return
        }

        // Cell-level fence guard: if this window is NOT directly fenced but shares a
        // cell with a fenced window, drop the event. This prevents collateral OS focus
        // events (e.g., a previously-focused co-cell window surfacing briefly) from
        // overwriting the lastFocusedWid that a move command set intentionally.
        if await isCellMateOfFencedWindow(windowID) {
            jlog("reconcile.focus.fenced.cell", data: ["wid": windowID])
            return
        }

        // Resolve spaceID and displayUUID.
        // Primary: look up the window's actual space from GridState (authoritative
        // after moves, since we update GridState synchronously).
        // Fallback: metadata.activeSpaceID (for windows not yet in GridState).
        var spaceID: String
        var displayUUID: String

        if let gridSpaceID = await gridState.findSpaceContaining(windowID: windowID) {
            // Window is tracked in GridState — use its actual space
            spaceID = gridSpaceID
            let wmState = await stateProvider.getState()
            displayUUID = findDisplayUUIDForSpace(gridSpaceID, from: wmState) ?? ""
        } else if focusState.spaceID != 0 {
            // Event carries space info (rare but handle it)
            spaceID = String(focusState.spaceID)
            displayUUID = focusState.displayUUID
        } else {
            // Window not in GridState — fall back to metadata
            let wmState = await stateProvider.getState()
            guard let resolved = findCurrentSpaceID(from: wmState) else { return }
            spaceID = resolved
            displayUUID = findCurrentDisplayUUID(from: wmState) ?? ""
        }

        // Detect space change
        let spaceChanged = focusState.previousSpaceID != nil
            && focusState.previousSpaceID != focusState.spaceID
            && focusState.spaceID != 0

        if spaceChanged {
            await handleSpaceChanged(
                newSpaceID: spaceID,
                displayUUID: displayUUID
            )
        }

        // Update GridState focus to match OS focus
        let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        if let cellID {
            let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
            let windowIndex = cellWindows.firstIndex(of: windowID) ?? 0
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)
        }

        // Update border focus and sync
        if !displayUUID.isEmpty {
            await borderRenderer?.updateFocus(
                newFocusedWindow: windowID,
                displayUUID: displayUUID
            )
            await syncBordersForSpace(spaceID, displayUUID: displayUUID)
        }
    }

    private func handleSpaceChanged(newSpaceID: String, displayUUID: String) async {
        // When user switches spaces, the new space may or may not have a layout
        guard let gridState else { return }

        let layoutID = await gridState.getCurrentLayout(spaceID: newSpaceID)
        if !layoutID.isEmpty {
            // Space has a layout -- sync borders for it
            await syncBordersForSpace(newSpaceID, displayUUID: displayUUID)
        }
        // No layout on this space -- borders will be empty
        // (SimpleBorderManager handles this via empty assignments on next sync)

        jlog("reconcile.space.change", data: ["space": newSpaceID, "display": displayUUID])
    }

    // macOS reassigned a space ID on a display (fullscreen app create/destroy).
    // Migrate GridState from the old ID to the new one so window assignments
    // survive, and reset AX orphan counts so the validator doesn't prune
    // windows that are only transiently invisible during the shuffle.
    private func handleSpaceIDReassigned(
        oldSpaceID: String,
        newSpaceID: String,
        displayUUID: String
    ) async {
        guard let gridState else { return }

        let migratedWids = await gridState.migrateSpace(from: oldSpaceID, to: newSpaceID)

        if !migratedWids.isEmpty {
            // Reset orphan tracking — these windows are real, just briefly
            // invisible to AX during the space ID transition.
            await stateValidator?.resetOrphanCounts(for: migratedWids)

            // Sync borders for the new space ID so they don't go blank.
            await syncBordersForSpace(newSpaceID, displayUUID: displayUUID)

            jlog("reconcile.space.reassign", data: [
                "old": oldSpaceID,
                "new": newSpaceID,
                "display": displayUUID,
                "migratedWindows": migratedWids.count,
            ])
        } else {
            jlog("reconcile.space.reassign.noop", data: [
                "old": oldSpaceID,
                "new": newSpaceID,
                "display": displayUUID,
            ])
        }
    }

    // Plain desktop switch (#2/#20): the space already exists, nothing to
    // migrate. Resync borders for the newly-active space so the highlight
    // follows the switch instead of going stale. Replaces the dead
    // FocusState.previous*-gated handleSpaceChanged border path.
    private func handleSpaceActivated(spaceID: String, displayUUID: String) async {
        guard !displayUUID.isEmpty else {
            jlog("reconcile.space.activated.no_display", data: ["space": spaceID])
            return
        }
        await syncBordersForSpace(spaceID, displayUUID: displayUUID)
        jlog("reconcile.space.activated", data: ["space": spaceID, "display": displayUUID])
    }

    // Debounce window for geometry-only display reconfiguration (#25). Multiple
    // didChangeScreenParameters notifications fire in a burst during a
    // resolution change or Dock animation; coalesce them into one reapply.
    private var geometryReapplyTask: Task<Void, Never>?

    // #25: resolution/scaling/Dock geometry changed for a display with the same
    // UUID. Reapply layouts (debounced) so windows resize to the new bounds.
    private func handleDisplayGeometryChanged(_ displayUUID: String) async {
        jlog("reconcile.dsp.geometry", data: ["display": displayUUID])

        geometryReapplyTask?.cancel()
        geometryReapplyTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let errors = await self.gridApply?.refreshAllDisplays(displayFilter: displayUUID) ?? []
            if !errors.isEmpty {
                jlog("warn.reconcile.dsp.geometry.errors",
                     data: ["display": displayUUID, "errorCount": errors.count])
            }
        }
    }

    private func handleSystemWake() async {
        guard let stateProvider, let gridState else { return }

        jlog("reconcile.wake.start")

        // Capture wmState once for consistency across all steps
        let wmState = await stateProvider.getState()

        // Store the validation work as a tracked task so commands can await completion
        // via awaitWakeCompletion(). The task reference is cleared on completion.
        let task = Task { [weak self] in
            guard let self else { return }

            // Step 0: Resume the validator ONLY when the screen is unlocked
            // (DW-2.5, #23). At the login screen AX returns reduced window
            // lists that false-positive ax_orphan-prune real tiled windows.
            // If still locked, the validator stays paused; the later
            // screenUnlocked event resumes it.
            if self.screenLocked {
                jlog("reconcile.wake.validator.deferred")
            } else {
                await self.stateValidator?.resume()
            }

            // Step 1: Migrate space IDs (macOS may reassign after sleep)
            var displaySpaces: [String: [String]] = [:]
            for display in wmState.displays {
                var spaceIDs: [String] = []
                for (spaceKey, space) in wmState.spaces {
                    if space.displayUUID == display.uuid {
                        spaceIDs.append(spaceKey)
                    }
                }
                // #6: numeric sort for positional matching ([String].sorted()
                // is lexicographic, pairing "999" ahead of "1001").
                displaySpaces[display.uuid] = SpaceMigrationPolicy.numericallySorted(spaceIDs)
            }

            let migrated = await gridState.migrateSpaceIDs(currentDisplaySpaces: displaySpaces)
            if migrated {
                jlog("reconcile.wake.migrated")
            }

            // Step 1.5: Reset AX orphan counts before validate runs so
            // pre-sleep stale counts cannot push real windows past the
            // 2-cycle prune threshold during the wake stabilization window.
            await self.stateValidator?.resetAllOrphanCounts()

            // Step 2: Full state validation after migration.
            // Re-fetch wmState so validator sees correct space IDs post-migration.
            let freshWmState = await stateProvider.getState()
            await self.stateValidator?.validate(wmState: freshWmState)

            // Step 2.5: Reapply layouts on every active space. Display
            // reconnect already does this (handleDisplayConnected); wake
            // must too, otherwise windows do not snap back into cells
            // after sleep. refreshAllDisplays does not throw — failures
            // are returned as a per-display error array.
            jlog("reconcile.wake.refresh.start")
            let refreshErrors = await self.gridApply?.refreshAllDisplays() ?? []
            if !refreshErrors.isEmpty {
                jlog("warn.reconcile.wake.refresh.errors",
                     data: ["errorCount": refreshErrors.count])
            }

            // Step 3: Sync borders for current space
            await self.syncBordersForCurrentSpace()

            jlog("reconcile.wake.done")

            // Clear the task reference so subsequent commands pass through immediately
            self.wakeValidationTask = nil
        }
        wakeValidationTask = task

        // Await the task so handleSystemWake() itself doesn't return until
        // everything is done. This preserves the existing guarantee that wake
        // handling is synchronous from the event handler's perspective.
        await task.value
    }

    private func handleWindowMoved(_ windowID: UInt32, _ frame: CGRect) async {
        await borderRenderer?.handleWindowMoved(windowID: windowID, newFrame: frame)

        // Re-evaluate rejected windows that may now be tileable (e.g. Ghostty
        // emits a 0x0 AX window at creation, then resizes to real dimensions).
        guard let gridState, await gridState.isWindowRejected(windowID) else { return }
        let nowTileable = frame.width >= 100 && frame.height >= 100
        guard nowTileable else { return }

        guard let stateProvider else { return }
        let wmState = await stateProvider.getState()
        guard let windowState = wmState.windows[String(windowID)] else { return }

        // Full isTileable check before unrejecting — prevents reject-unreject
        // loops for windows with valid dimensions but non-standard subrole
        // (e.g. Chrome AXUnknown dropdowns).
        guard isTileable(window: windowState) else { return }

        await gridState.unrejectWindow(windowID)
        jlog("reconcile.win.unrejected", data: ["wid": windowID, "w": frame.width, "h": frame.height])

        if pendingLaunchTarget != nil {
            await handlePendingLaunchWindow(windowID, windowState.pid)
        } else {
            await handleWindowCreated(windowID, windowState.pid)
        }
    }

    private func handleWindowMinimized(_ windowID: UInt32) async {
        // Minimized window should be removed from cell assignment.
        guard let gridState else { return }

        // #30: resolve the window's TRACKED space, not the focused display's
        // active space. A window minimized on another display/space (or via
        // CLI) was previously removed from the wrong space (a silent no-op),
        // leaving its cell slot reserved forever. Fall back to all-spaces.
        if let trackedSpaceID = await gridState.findSpaceContaining(windowID: windowID) {
            await gridState.removeWindow(windowID, fromSpace: trackedSpaceID)
        } else {
            await gridState.removeWindowFromAllSpaces(windowID)
        }
        await syncBordersForCurrentSpace()

        jlog("reconcile.win.min", data: ["wid": windowID])
    }

    private func handleWindowDeminimized(_ windowID: UInt32) async {
        // Treat like a new window creation for tiling purposes
        guard let stateProvider else { return }
        let wmState = await stateProvider.getState()
        guard let windowState = wmState.windows[String(windowID)] else { return }

        let pid = windowState.pid
        await handleWindowCreated(windowID, pid)

        jlog("reconcile.win.unmin", data: ["wid": windowID])
    }

    // handleDisplayConnected
    //
    // Triggered when a display is reconnected (e.g., external monitor plugged back in).
    // GridState retains the layout and window assignments from before disconnect.
    // Re-syncs borders and reapplies layouts for the reconnected display.
    private func handleDisplayConnected(_ displayUUID: String) async {
        jlog("reconcile.display.connect", data: ["display": displayUUID])

        // Short delay allows macOS to stabilize space/window state after reconnect
        // before we query it. Without this, wmState may not yet reflect new spaces.
        // 500ms is enough for display negotiation; short enough to feel instant.
        try? await Task.sleep(for: .milliseconds(500))

        // Reapply layouts and sync borders for the reconnected display.
        // refreshAllDisplays handles: find active space, check layout,
        // reapply window positions, sync borders.
        let errors = await gridApply?.refreshAllDisplays(displayFilter: displayUUID) ?? []

        if !errors.isEmpty {
            jlog("warn.reconcile.display.connect.errors",
                 data: ["display": displayUUID, "errorCount": errors.count])
        }
    }

    // handleDisplayDisconnected
    //
    // Enhanced disconnect handler. Previous behavior only cleaned up borders.
    // New behavior also prunes GridState window assignments for spaces on the
    // disconnected display, preventing zombies from accumulating.
    //
    // Why windows but not spaces: macOS may keep space IDs alive for disconnected
    // displays. pruneDeadSpaces() (StateValidator) handles space cleanup when the
    // IDs are actually gone. Removing windows eagerly prevents zombie assignments
    // in cells while preserving layout config for reconnect.
    private func handleDisplayDisconnected(_ displayUUID: String) async {
        jlog("reconcile.display.disconnect", data: ["display": displayUUID])

        // Existing: clean up border state for this display
        await borderRenderer?.handleDisplayDisconnected(displayUUID: displayUUID)

        // New: prune GridState window assignments for spaces on this display
        guard let gridState, let stateProvider else { return }
        let wmState = await stateProvider.getState()

        // #52: union the post-refresh wmState spaces (may be empty — the display
        // is already gone from SLS) with GridState's OWN per-display snapshot,
        // which still remembers the disconnected display's spaces. The old
        // wmState-only lookup was dead code on a real disconnect.
        var affectedSpaceIDs = Set(wmState.spaces.compactMap { (spaceID, space) -> String? in
            space.displayUUID == displayUUID ? spaceID : nil
        })
        affectedSpaceIDs.formUnion(await gridState.getSpaceIDsForDisplay(displayUUID))

        if affectedSpaceIDs.isEmpty {
            jlog("reconcile.display.disconnect.no_spaces", data: ["display": displayUUID])
            return
        }

        // For each affected space, remove all window assignments.
        // Windows will reappear via windowCreated events when the display reconnects
        // and the user's apps are still running.
        for spaceID in affectedSpaceIDs {
            let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
            for (_, windowIDs) in assignments {
                for windowID in windowIDs {
                    await gridState.removeWindow(windowID, fromSpace: spaceID)
                    jlog("reconcile.display.disconnect.prune",
                         data: ["wid": Int(windowID), "space": spaceID, "display": displayUUID])
                }
            }
        }
    }

    // MARK: - Border Sync

    private func syncBordersForCurrentSpace(source: String = "reconcile") async {
        // Get current space and display from StateManager
        guard let stateProvider else { return }

        let wmState = await stateProvider.getState()
        guard let spaceID = findCurrentSpaceID(from: wmState),
              let displayUUID = findCurrentDisplayUUID(from: wmState) else {
            return
        }

        await syncBordersForSpace(spaceID, displayUUID: displayUUID, source: source)
    }

    // Compute the live wids known to StateManager for a display — used as the
    // `live_wids` payload on bdr.empty so post-mortem can tell what windows
    // the state machine believed existed when an empty assignment was sent.
    private func computeLiveWids(displayUUID: String, wmState: WindowManagerState) -> [UInt32] {
        var wids: [UInt32] = []
        for (_, win) in wmState.windows {
            if win.displayUUID == displayUUID {
                wids.append(win.id)
            }
        }
        return wids
    }

    func syncBordersForSpace(_ spaceID: String, displayUUID: String, source: String = "reconcile") async {
        guard let gridState, let gridConfig else { return }

        // Get layout for this space
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else {
            // No layout -- clear borders by sending empty assignments
            let liveWids: [UInt32]
            if let stateProvider {
                let wmState = await stateProvider.getState()
                liveWids = computeLiveWids(displayUUID: displayUUID, wmState: wmState)
            } else {
                liveWids = []
            }
            await borderRenderer?.setCellAssignments(
                [:],
                forDisplay: displayUUID,
                focusedWindowID: nil,
                cellStackModes: [:],
                windowOrder: nil,
                displayFrame: nil,
                source: "no_layout:\(source)",
                liveWids: liveWids
            )
            return
        }

        // Get layout definition (GridConfig is @MainActor)
        let layoutDef: GridLayoutDef
        do {
            layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }
        } catch {
            return
        }

        // Get display bounds for layout calculation
        guard let stateProvider else { return }
        let wmState = await stateProvider.getState()
        guard let bounds = findDisplayBounds(displayUUID: displayUUID, from: wmState) else {
            return
        }

        // Calculate cell bounds
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        // Calculate layout to validate it exists; cell bounds used by border manager
        _ = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: bounds,
            gap: baseSpacing,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // Build window-to-cell assignments map
        let spaceAssignments = await gridState.getWindowAssignments(spaceID: spaceID)
        var windowToCellMap: [UInt32: String] = [:]
        var cellStackModes: [String: String] = [:]
        var windowOrder: [String: [UInt32]] = [:]

        for (cellID, windowIDs) in spaceAssignments {
            for wid in windowIDs {
                windowToCellMap[wid] = cellID
            }
            windowOrder[cellID] = windowIDs

            // Get stack mode for cell
            let mode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID)
            cellStackModes[cellID] = mode?.rawValue ?? "tabs"
        }

        // Get focused window
        let focusedWID = await gridState.getFocusedWindow(spaceID: spaceID)

        // Send to border renderer. The async protocol replaces the old
        // withCheckedContinuation + completion callback pattern -- the
        // conformance bridges DispatchQueue.main internally.
        let liveWids = computeLiveWids(displayUUID: displayUUID, wmState: wmState)
        await borderRenderer?.setCellAssignments(
            windowToCellMap,
            forDisplay: displayUUID,
            focusedWindowID: focusedWID != 0 ? focusedWID : nil,
            cellStackModes: cellStackModes,
            windowOrder: windowOrder,
            displayFrame: bounds,
            source: source,
            liveWids: liveWids
        )
    }

    // MARK: - Helpers

    private func findCurrentSpaceID(from wmState: WindowManagerState) -> String? {
        // Use metadata.activeSpaceID which tracks the focused display's space
        // (with multiple monitors, each display has its own active space)
        if let activeSpaceID = wmState.metadata.activeSpaceID {
            return String(activeSpaceID)
        }
        for (spaceKey, space) in wmState.spaces {
            if space.isActive {
                return spaceKey
            }
        }
        return nil
    }

    private func findCurrentDisplayUUID(from wmState: WindowManagerState) -> String? {
        // Use metadata.activeDisplayUUID which tracks the focused display
        if let activeDisplayUUID = wmState.metadata.activeDisplayUUID {
            return activeDisplayUUID
        }
        for (_, space) in wmState.spaces {
            if space.isActive {
                return space.displayUUID
            }
        }
        return nil
    }

    // Determine which tracked space a window belongs to using its OS-level
    // space list. Picks the first space that has an active layout in GridState.
    // Falls back to the focused space if the window's spaces are empty or
    // none have layouts (e.g. window just created, spaces not yet populated).
    private func resolveWindowSpace(
        _ windowState: WindowState,
        gridState: GridState,
        wmState: WindowManagerState
    ) async -> String? {
        for osSpace in windowState.spaces {
            let sid = String(osSpace)
            let layout = await gridState.getCurrentLayout(spaceID: sid)
            if !layout.isEmpty {
                return sid
            }
        }
        return findCurrentSpaceID(from: wmState)
    }

    private func findDisplayUUIDForSpace(_ spaceID: String, from wmState: WindowManagerState) -> String? {
        for display in wmState.displays {
            if String(display.currentSpaceID) == spaceID {
                return display.uuid
            }
        }
        return nil
    }

    private func findDisplayBounds(displayUUID: String, from wmState: WindowManagerState) -> CGRect? {
        for display in wmState.displays {
            if display.uuid == displayUUID {
                return display.visibleFrame ?? display.frame
            }
        }
        return nil
    }

    // resolveDisplacedTarget: pure decision predicate for sweepDisplacedWindows.
    //
    // Given the space GridState believes the window is on (trackedSpaceID),
    // the actual OS-reported spaces for that window (actualSpaces), and the
    // set of space IDs currently tracked in GridState (knownSpaceIDs):
    //
    //   - Returns nil  → no migration (window still on tracked space, or skip
    //                     due to ambiguity / untracked target)
    //   - Returns spaceID → migrate to that space (exactly one unambiguous match)
    //
    // Extracted as a static pure helper so tests can verify all four decision
    // branches without driving the full reconciler/actor stack.
    static func resolveDisplacedTarget(
        trackedSpaceID: String,
        actualSpaces: [UInt64],
        knownSpaceIDs: Set<String>
    ) -> String? {
        // Empty actualSpaces: minimized or off-screen — skip
        guard !actualSpaces.isEmpty else { return nil }

        // Window still on its tracked space — no displacement
        if let trackedUInt64 = UInt64(trackedSpaceID), actualSpaces.contains(trackedUInt64) {
            return nil
        }

        // Find candidate target spaces: actual spaces that GridState tracks
        let candidates = actualSpaces.filter { knownSpaceIDs.contains(String($0)) }

        // Ambiguous (multiple tracked candidates) or untracked target — skip
        guard candidates.count == 1 else { return nil }

        return String(candidates[0])
    }

    // pickTargetCell: choose the auto-assign destination cell for a new window.
    //
    // Prefers the focused cell when it is known, present in assignments, and not
    // reserved by a locked app rule. Falls back to the least-populated cell.
    // Extracted as a static pure helper so tests can verify the decision logic
    // without driving the full reconciler stack.
    static func pickTargetCell(
        focusedCell: String?,
        assignments: [String: [UInt32]],
        locked: Set<String>
    ) -> String {
        if let focused = focusedCell,
           !focused.isEmpty,
           assignments[focused] != nil,
           !locked.contains(focused) {
            return focused
        }
        let candidates = assignments.keys.filter { !locked.contains($0) }
        return candidates.sorted().min { a, b in
            (assignments[a]?.count ?? 0) < (assignments[b]?.count ?? 0)
        } ?? ""
    }

    // sweepDisplacedWindows: detect and migrate windows whose OS-level space no longer
    // matches their GridState-tracked space. Called at every suppression-depth-0 exit
    // so windows that changed spaces while suppressed are reconciled immediately.
    //
    // Skip cases (conservative — never guess):
    //   - wmState has no entry for the window (recently destroyed / invisible)
    //   - window.spaces is empty (minimized or off-screen)
    //   - window is still on its tracked space (no displacement)
    //   - window is on multiple tracked spaces simultaneously (ambiguous)
    //   - window moved to a space not tracked by GridState (unmanaged space)
    private func sweepDisplacedWindows() async {
        guard let gridState, let stateProvider else { return }

        let wmState = await stateProvider.getState()
        let trackedSpaceIDs = Set(await gridState.getSpaceIDs())
        var affectedSpaces = Set<String>()

        // Collect (wid, sourceCell, sourceSpace, targetSpace, targetCell) tuples so
        // we can apply cell layouts after all state mutations complete.
        struct Migration {
            let wid: UInt32
            let sourceSpaceID: String
            let sourceCell: String
            let targetSpaceID: String
            let targetCell: String
        }
        var migrations: [Migration] = []

        let allWids = await gridState.getAllWindowIDs()

        let sweepNow = CFAbsoluteTimeGetCurrent()

        for wid in allWids {
            // FIX 1 / DW-D2: a window deliberately moved across spaces is exempt
            // from displaced-sweep correction until its grace expires (by which
            // time the lagging SLS space query catches up). Skipping here
            // prevents the just-moved window bouncing back to its origin space.
            if GraceWindowPolicy.withinCrossMoveGrace(
                movedAt: crossMoveGrace[wid],
                now: sweepNow,
                graceSeconds: crossMoveGraceSeconds
            ) {
                jlog("reconcile.lift.skip", data: [
                    "wid": Int(wid),
                    "reason": "recent_cross_move",
                ])
                continue
            }
            // Prune an expired cross-move grace entry once it no longer gates.
            if crossMoveGrace[wid] != nil {
                crossMoveGrace[wid] = nil
            }

            // Resolve the space GridState believes this window is on
            guard let trackedSpaceID = await gridState.findSpaceContaining(windowID: wid) else {
                continue
            }

            // Resolve the actual OS-level spaces for this window
            guard let actualSpaces = wmState.windows[String(wid)]?.spaces else {
                // Unknown to StateManager — skip (recently destroyed or invisible)
                continue
            }

            // Delegate displacement decision to pure static helper
            guard let targetSpaceID = GridReconciler.resolveDisplacedTarget(
                trackedSpaceID: trackedSpaceID,
                actualSpaces: actualSpaces,
                knownSpaceIDs: trackedSpaceIDs
            ) else {
                continue
            }

            // Record the source cell before state mutation
            let sourceCell = await gridState.getWindowCell(windowID: wid, inSpace: trackedSpaceID) ?? ""
            let targetCell = await gridState.getFocusedCell(spaceID: targetSpaceID) ?? "left"

            await gridState.removeWindow(wid, fromSpace: trackedSpaceID)
            await gridState.assignWindow(wid, toCellID: targetCell, inSpace: targetSpaceID)

            jlog("reconcile.lift.migrate", data: [
                "wid": Int(wid),
                "from": trackedSpaceID,
                "to": targetSpaceID,
                "cell": targetCell,
            ])

            migrations.append(Migration(
                wid: wid,
                sourceSpaceID: trackedSpaceID,
                sourceCell: sourceCell,
                targetSpaceID: targetSpaceID,
                targetCell: targetCell
            ))
            affectedSpaces.insert(trackedSpaceID)
            affectedSpaces.insert(targetSpaceID)
        }

        // Apply cell layout for both target and vacated source cells so that
        // window geometry matches the new assignments (#19).
        for migration in migrations {
            try? await gridApply?.applyCellLayout(
                spaceID: migration.targetSpaceID,
                cellID: migration.targetCell
            )
            if !migration.sourceCell.isEmpty {
                try? await gridApply?.applyCellLayout(
                    spaceID: migration.sourceSpaceID,
                    cellID: migration.sourceCell
                )
            }
        }

        for spaceID in affectedSpaces {
            guard let displayUUID = findDisplayUUIDForSpace(spaceID, from: wmState) else {
                // Background space — no visible borders to update
                continue
            }
            await syncBordersForSpace(spaceID, displayUUID: displayUUID)
        }
    }

    private func findCurrentSpaceIDAsync() async -> String? {
        guard let stateProvider else { return nil }
        let wmState = await stateProvider.getState()
        return findCurrentSpaceID(from: wmState)
    }

    // MARK: - Test Helpers

    // _test_pendingLaunchTarget: read the current pending launch target.
    // Used only in tests to assert target-survival (skip-not-consume) behavior.
    func _test_pendingLaunchTarget() -> PendingLaunchTarget? {
        pendingLaunchTarget
    }

    // _test_setPendingLaunchTarget: arm a pending target directly (DW-4.2/4.3).
    func _test_setPendingLaunchTarget(_ target: PendingLaunchTarget?) {
        pendingLaunchTarget = target
    }

    // _test_handlePendingLaunchWindow: drive the pending-launch path (DW-4.2/4.3).
    func _test_handlePendingLaunchWindow(windowID: UInt32, pid: pid_t) async {
        await handlePendingLaunchWindow(windowID, pid)
    }

    // _test_notStandardGraceCount: number of windows tracked for not_standard
    // grace re-evaluation (DW-4.6).
    var _test_notStandardGraceCount: Int { notStandardGrace.count }

    // _test_noteCrossSpaceMove: record a cross-space move at an explicit time
    // so the grace gate can be exercised deterministically (DW-D2).
    func _test_noteCrossSpaceMove(_ windowID: UInt32, at time: CFAbsoluteTime) {
        crossMoveGrace[windowID] = time
    }

    // _test_shouldSkipDisplacedForGrace: drive the real grace map through the
    // real predicate exactly as sweepDisplacedWindows does (DW-D2).
    func _test_shouldSkipDisplacedForGrace(wid: UInt32, now: CFAbsoluteTime) -> Bool {
        GraceWindowPolicy.withinCrossMoveGrace(
            movedAt: crossMoveGrace[wid],
            now: now,
            graceSeconds: crossMoveGraceSeconds
        )
    }

    // _test_setWindowController: inject the WindowController port (DW-4.4).
    func _test_setWindowController(_ controller: any WindowController) {
        self.windowController = controller
    }

    // _test_notStandardGraceSweep: drive the grace re-evaluation sweep (DW-4.6).
    func _test_notStandardGraceSweep() async {
        await notStandardGraceSweep()
    }

    // _test_adoptUntrackedTileables: drive the depth-0 adoption scan (DW-4.8).
    func _test_adoptUntrackedTileables() async {
        await adoptUntrackedTileables()
    }

    // _test_suppressionDepth: current suppression depth, for action-token tests (DW-1.4).
    var _test_suppressionDepth: Int { suppressionDepth }

    // _test_isFenced: whether windowID is currently fenced (DW-1.3).
    func _test_isFenced(_ windowID: UInt32) -> Bool {
        isWindowFenced(windowID)
    }

    // _test_suppressedQueueCount: number of events currently queued during
    // suppression, for replay tests (DW-1.6).
    var _test_suppressedQueueCount: Int { suppressedEvents.count }

    // _test_handle: drive the public StateEventHandler entry point so a test can
    // exercise the suppressed-event queueing branch through real wiring.
    func _test_handle(_ event: StateEvent) async {
        try? await handle(event, context: EventContext(source: .manual(reason: "test")))
    }

    // _test_setup: minimal wiring for tests -- sets stateProvider and gridState
    // without registering with EventRouter or starting sweep timers.
    // Optional appRules override bypasses the gridConfig lookup in handleWindowCreated.
    func _test_setup(
        stateProvider: any StateProvider,
        gridState: GridState,
        gridConfig: GridConfig? = nil,
        lockedRules: [GridAppRule]? = nil,
        borderRenderer: (any BorderRendering)? = nil
    ) {
        self.stateProvider = stateProvider
        self.gridState = gridState
        self._test_appRuleOverride = lockedRules
        if let gridConfig {
            self.gridConfig = gridConfig
        }
        if let borderRenderer {
            self.borderRenderer = borderRenderer
        }
    }

    // Test-only override for app rules. When non-nil, handleWindowCreated
    // reads from here instead of querying gridConfig on MainActor.
    var _test_appRuleOverride: [GridAppRule]?

    // _test_triggerWindowCreated: delegates to the private handleWindowCreated
    // so tests can exercise the full orchestration path with injected fakes.
    func _test_triggerWindowCreated(windowID: UInt32, pid: pid_t) async {
        await handleWindowCreated(windowID, pid)
    }

    // _test_triggerWindowDestroyed: delegates to the private handleWindowDestroyed
    // so tests can verify border port wiring.
    func _test_triggerWindowDestroyed(windowID: UInt32) async {
        await handleWindowDestroyed(windowID)
    }

    // _test_triggerFocusChanged: delegates to the private handleFocusChanged
    // so tests can verify border port wiring for focus events.
    func _test_triggerFocusChanged(windowID: UInt32, spaceID: UInt64, displayUUID: String) async {
        let focusState = FocusState(
            windowID: windowID,
            spaceID: spaceID,
            displayUUID: displayUUID,
            trigger: .windowActivated
        )
        await handleFocusChanged(focusState)
    }

    // _test_triggerSyncBorders: delegates to syncBordersForSpace
    // so tests can verify setCellAssignments port wiring.
    func _test_triggerSyncBorders(spaceID: String, displayUUID: String) async {
        await syncBordersForSpace(spaceID, displayUUID: displayUUID, source: "test")
    }

    // _test_sweepDisplacedWindows: expose the private sweep for DW-5.3 integration tests.
    func _test_sweepDisplacedWindows() async {
        await sweepDisplacedWindows()
    }

    // _test_setGridApply: inject a GridApply instance with test hooks (DW-5.3).
    func _test_setGridApply(_ apply: GridApply) {
        self.gridApply = apply
    }
}
