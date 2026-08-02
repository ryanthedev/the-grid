//
// StateValidator.swift
// GridServer
//
// Periodic and on-wake validator: removes zombie windows, deduplicates
// windows appearing in multiple spaces, and prunes stale space IDs.
//

import Foundation
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

actor StateValidator {

    // MARK: - Properties

    private weak var gridState: GridState?
    private weak var stateProvider: (any StateProvider)?

    // SkyLight connection for SLSGetWindowBounds liveness checks
    private let connectionID: Int32

    private var timer: DispatchSourceTimer?

    // Validation interval: 30 seconds
    private let validationInterval: TimeInterval = 30.0

    // Track consecutive AX-orphan detections per window.
    // A window must be orphaned for 2+ consecutive cycles before pruning
    // to avoid false positives during transient states (app launch, window creation).
    private var axOrphanCounts: [UInt32: Int] = [:]
    private let axOrphanThreshold = 2

    // Heartbeat tick counter: increments every validation cycle (30s). Used by
    // HeartbeatScheduler to emit `srv.alive` at a 60s cadence for memory-growth
    // correlation on crashes.
    private var heartbeatTickCount: Int = 0

    // Paused: when true, validate(wmState:) early-returns without running any
    // prune passes. Toggled by pause()/resume() in response to system sleep
    // and screen lock/unlock events. Single Bool (not refcounted) — wake
    // unconditionally clears it via resume() in handleSystemWake.
    private var paused: Bool = false

    // MARK: - Initialization

    init(gridState: GridState, stateProvider: any StateProvider, connectionID: Int32) {
        self.gridState = gridState
        self.stateProvider = stateProvider
        self.connectionID = connectionID
    }

    // MARK: - Public API

    // Reset AX orphan tracking for specific windows. Called when macOS
    // reassigns space IDs — windows on the affected space become temporarily
    // invisible to AX during the transition and would otherwise be pruned.
    func resetOrphanCounts(for windowIDs: [UInt32]) {
        var cleared = 0
        for wid in windowIDs {
            if axOrphanCounts.removeValue(forKey: wid) != nil {
                cleared += 1
            }
        }
        if cleared > 0 {
            jlog("validate.orphan.reset", data: [
                "cleared": cleared,
                "total": windowIDs.count,
            ])
        }
    }

    // Reset ALL AX orphan tracking. Called on system wake before validate()
    // runs so pre-sleep stale counts cannot push real, alive windows past
    // the 2-cycle prune threshold during the wake stabilization window.
    // Distinct from resetOrphanCounts(for:): this clears the entire map
    // rather than a specific subset.
    func resetAllOrphanCounts() {
        let cleared = axOrphanCounts.count
        axOrphanCounts.removeAll()
        if cleared > 0 {
            jlog("validate.orphan.reset.all", data: [
                "cleared": cleared,
            ])
        }
    }

    // pause -- mark the validator as paused. Subsequent validate(wmState:)
    // calls early-return until resume() is called. Idempotent: calling
    // pause() twice is the same as calling it once. Triggered by system
    // willSleep and screen lock events; AX queries during these states
    // return reduced window lists that cause false-positive ax_orphan
    // prunes.
    func pause() {
        if !paused {
            paused = true
            jlog("validate.pause")
        }
    }

    // resume -- clear the paused flag. Triggered by screen unlock and
    // unconditionally by system wake. Idempotent.
    func resume() {
        if paused {
            paused = false
            jlog("validate.resume")
        }
    }

    // MARK: - Test Helpers

    // peekHeartbeatTickCount: read-only accessor used by tests to verify
    // ordering (validate() increments heartbeatTickCount; observing >0
    // proves validate completed). Cheap actor read.
    func peekHeartbeatTickCount() -> Int {
        return heartbeatTickCount
    }

    // _test_seedOrphanCounts: directly populate the orphan-count map for
    // tests that exercise reset behavior without needing real AX queries.
    func _test_seedOrphanCounts(_ counts: [UInt32: Int]) {
        for (wid, n) in counts {
            axOrphanCounts[wid] = n
        }
    }

    // _test_orphanCountForWid: read the orphan count for a wid (0 if absent).
    func _test_orphanCountForWid(_ wid: UInt32) -> Int {
        return axOrphanCounts[wid] ?? 0
    }

    // _test_isPaused: read the paused flag (DW-2.5 wake-lock gating tests).
    func _test_isPaused() -> Bool {
        return paused
    }

    // start() -- called once from main.swift after all components are wired.
    // Creates a repeating background timer that fires validate() every 30 seconds.
    func start() {
        let queue = DispatchQueue(label: "com.thegrid.statevalidator", qos: .utility)
        let source = DispatchSource.makeTimerSource(queue: queue)

        source.schedule(
            deadline: .now() + validationInterval,
            repeating: validationInterval,
            leeway: .seconds(5)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                guard let stateProvider = await self.stateProvider else { return }
                let wmState = await stateProvider.getState()
                await self.validate(wmState: wmState)
            }
        }

        timer = source
        source.resume()

        jlog("validate.timer.start", data: ["intervalSeconds": validationInterval])
    }

    // validate(wmState:) -- called on wake and periodically.
    // Runs all three pruning passes in sequence. All mutations go through
    // GridState actor calls so this does not block the caller's thread.
    //
    // When paused (system asleep or screen locked), returns immediately
    // after emitting one `validate.skip.paused` jlog. AX queries during
    // these states return reduced window lists that previously caused
    // pruneAXOrphanedWindows to false-positive prune real windows.
    func validate(wmState: WindowManagerState) async {
        if paused {
            jlog("validate.skip.paused")
            return
        }

        jlog("validate.start")

        await pruneDeadWindows(wmState: wmState)
        await pruneAXOrphanedWindows(wmState: wmState)
        await deduplicateWindows(wmState: wmState)
        await pruneDeadSpaces(wmState: wmState)

        jlog("validate.end")

        // Heartbeat: emit every other tick (60s cadence at 30s validator
        // cadence). Primary purpose is ruling in/out heap growth on crashes.
        heartbeatTickCount += 1
        if HeartbeatScheduler.shouldEmit(tickCount: heartbeatTickCount) {
            jlog("srv.alive", data: [
                "heap_mb": Int(HeapReader.readHeapMb()),
                "focused_wid": Int(wmState.metadata.focusedWindowID ?? 0),
                "displays": wmState.displays.count,
                "total_wins": wmState.windows.count,
            ])
        }
    }

    // MARK: - Pruning Passes

    // pruneDeadWindows -- remove windows that no longer exist in SkyLight.
    // Skips minimized windows since SLSGetWindowBounds returns success for them.
    private func pruneDeadWindows(wmState: WindowManagerState) async {
        guard let gridState else { return }

        let allTrackedIDs = await gridState.getAllWindowIDs()

        for windowID in allTrackedIDs {
            // Guard: skip minimized windows -- SLSGetWindowBounds returns success
            // for minimized windows, so we must not prune them.
            if wmState.windows[String(windowID)]?.isMinimized == true {
                continue
            }

            // Check liveness via SkyLight private API
            var bounds = CGRect.zero
            let err = SLSGetWindowBounds(connectionID, windowID, &bounds)

            if err != .success {
                // Window is dead (destroyed) -- remove from all spaces
                await gridState.removeWindowFromAllSpaces(windowID)
                jlog("validate.win.prune", data: ["wid": windowID, "reason": "dead"])
            }
        }
    }

    // pruneAXOrphanedWindows -- remove windows that exist in SkyLight but are
    // not in their owner app's AX window list. These are "ghost" windows: the
    // CGWindowList entry persists but the window is inaccessible via accessibility
    // APIs, so it can't be focused or manipulated.
    //
    // Uses a 2-cycle threshold to avoid false positives during transient states
    // (app launch, window animation, etc.).
    private func pruneAXOrphanedWindows(wmState: WindowManagerState) async {
        guard let gridState else { return }

        let allTrackedIDs = await gridState.getAllWindowIDs()
        var stillOrphaned: Set<UInt32> = []

        // Group tracked windows by pid to batch AX lookups per app
        var pidToWindows: [pid_t: [UInt32]] = [:]
        for windowID in allTrackedIDs {
            if wmState.windows[String(windowID)]?.isMinimized == true {
                continue
            }
            guard let windowState = wmState.windows[String(windowID)] else { continue }
            pidToWindows[windowState.pid, default: []].append(windowID)
        }

        for (pid, windowIDs) in pidToWindows {
            let axWindowIDs = getAXWindowIDs(pid: pid)
            // If AX query failed entirely (app busy, no permission), skip — don't prune
            guard let axWindowIDs else { continue }

            for windowID in windowIDs {
                if !axWindowIDs.contains(windowID) {
                    stillOrphaned.insert(windowID)
                }
            }
        }

        // Update orphan counts: increment for still-orphaned, reset for recovered
        var newCounts: [UInt32: Int] = [:]
        for windowID in stillOrphaned {
            newCounts[windowID] = (axOrphanCounts[windowID] ?? 0) + 1
        }
        axOrphanCounts = newCounts

        // Prune windows that exceeded the threshold
        for (windowID, count) in axOrphanCounts where count >= axOrphanThreshold {
            await gridState.removeWindowFromAllSpaces(windowID)
            axOrphanCounts.removeValue(forKey: windowID)
            jlog("validate.win.prune", data: [
                "wid": windowID,
                "reason": "ax_orphan",
                "cycles": count,
            ])
        }
    }

    // axFailureMeansNoWindows -- classify a failed kAXWindows query.
    //
    // Extracted as a pure static (mirroring StateManager.shouldUseSoleWindowFallback)
    // so the distinction can be unit-tested off the AX boundary. It is the only
    // thing separating "this process genuinely owns no windows, an empty set is
    // accurate" from "the app is busy or unreachable, we know nothing" — and
    // getting it backwards makes every window of an unresponsive app look
    // orphaned, which prunes all of them after two cycles.
    //
    // true  => report an empty set; callers may treat the app's windows as absent.
    // false => report nil; callers must skip this pid and prune nothing.
    static func axFailureMeansNoWindows(_ result: AXError) -> Bool {
        // .attributeUnsupported = non-windowed process (agent/daemon), definitive.
        // .cannotComplete / .notImplemented / anything else = app busy or
        // unusual, and absence of evidence is not evidence of absence.
        return result == .attributeUnsupported
    }

    // Get all window IDs visible via AX for a given pid.
    // Returns nil if the AX query fails (app unresponsive, no permission).
    private func getAXWindowIDs(pid: pid_t) -> Set<UInt32>? {
        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return Self.axFailureMeansNoWindows(result) ? Set() : nil
        }

        var ids = Set<UInt32>()
        for window in windows {
            var windowID: UInt32 = 0
            if _AXUIElementGetWindow(window, &windowID) == .success {
                ids.insert(windowID)
            }
        }
        return ids
    }

    // deduplicateWindows -- remove windows from all-but-one space when a window
    // appears in multiple GridState spaces. Keeps the "best" space per window.
    private func deduplicateWindows(wmState: WindowManagerState) async {
        guard let gridState else { return }

        // Collect all tracked windows and which spaces they appear in per GridState
        var windowSpaces: [UInt32: [String]] = [:]

        let spaceIDs = await gridState.getSpaceIDs()
        for spaceID in spaceIDs {
            let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
            for (_, windowIDs) in assignments {
                for wid in windowIDs {
                    windowSpaces[wid, default: []].append(spaceID)
                }
            }
        }

        // For each window in more than one space, keep it in the best space only
        for (wid, spaceIDsForWindow) in windowSpaces where spaceIDsForWindow.count > 1 {
            let keepSpaceID = pickBestSpace(
                wid: wid,
                spaceIDs: spaceIDsForWindow,
                wmState: wmState
            )

            for spaceID in spaceIDsForWindow where spaceID != keepSpaceID {
                await gridState.removeWindow(wid, fromSpace: spaceID)
                jlog("validate.win.dedup", data: [
                    "wid": wid,
                    "removedFrom": spaceID,
                    "keptIn": keepSpaceID,
                ])
            }
        }
    }

    // pruneDeadSpaces -- remove spaces from GridState that no longer exist in wmState.
    // wmState.spaces is the authoritative live set of space IDs.
    private func pruneDeadSpaces(wmState: WindowManagerState) async {
        guard let gridState else { return }

        let liveSpaceIDs = Set(wmState.spaces.keys)
        let trackedSpaceIDs = await gridState.getSpaceIDs()

        for spaceID in trackedSpaceIDs {
            if !liveSpaceIDs.contains(spaceID) {
                await gridState.removeSpace(spaceID)
                jlog("validate.space.prune", data: ["spaceID": spaceID])
            }
        }
    }

    // MARK: - Tie-Breaking

    // pickBestSpace -- determine which space a duplicated window should live in.
    // Priority:
    //   1. Space matching the window's actual OS-reported space (from wmState.windows)
    //   2. Active space on any display (fallback)
    //   3. First in list (deterministic final fallback)
    private func pickBestSpace(
        wid: UInt32,
        spaceIDs: [String],
        wmState: WindowManagerState
    ) -> String {
        // Get the window's actual OS-reported spaces from wmState
        let osWindowSpaces: Set<UInt64>
        if let windowState = wmState.windows[String(wid)] {
            osWindowSpaces = Set(windowState.spaces)
        } else {
            osWindowSpaces = Set()
        }

        // Prefer a GridState space that matches a known OS space for this window
        for spaceID in spaceIDs {
            if let spaceIDInt = UInt64(spaceID), osWindowSpaces.contains(spaceIDInt) {
                return spaceID
            }
        }

        // Fallback: prefer the active space on any display
        for display in wmState.displays {
            let activeSpaceID = String(display.currentSpaceID)
            if spaceIDs.contains(activeSpaceID) {
                return activeSpaceID
            }
        }

        // Final fallback: first in list (arbitrary but stable within a run)
        return spaceIDs[0]
    }
}
