//
// PickerManager.swift
// GridServer
//
// Singleton orchestrator for the picker lifecycle
// Follows SimpleBorderManager pattern: main-thread class, not actor
//

import AppKit

/// Orchestrates the picker window lifecycle and async item discovery
/// All methods must be called on the main thread
class PickerManager {
    static let shared = PickerManager()

    private var window: PickerWindow?
    private var discoveryTask: Task<Void, Never>?
    private var isVisible = false

    // Stored continuation for RPC callers awaiting a picker result
    private var pendingRPCContinuation: CheckedContinuation<PickerResult, Never>?

    // History: loaded once on init, saved on each selection
    private var history: PickerHistory

    // All items accumulated during current session (for global frecency re-sort)
    private var allItems: [PickerItem] = []

    // Grid config for picker sources (actions, zoxide path)
    private var gridConfig: GridConfig?

    // Window that was focused before the picker was shown (for cancel restoration)
    private var previousWindowID: UInt32?
    private var previousWindowPID: pid_t?
    private var windowManipulator: WindowManipulator?
    private var gridReconciler: GridReconciler?
    private var gridState: GridState?
    private var isHandlingResult: Bool = false

    // Optional callback invoked when a launch-type action is selected
    // Set by GridCommandRouter before show(), cleared in hide()
    var onLaunch: ((PickerAction) -> Void)?

    private init() {
        // Load history from disk on server start
        history = PickerHistory.load()
        jlog("pick.hist.loaded", data: [
            "entries": "\(history.frequency.count)",
            "previous": history.previous
        ])
    }

    /// Configure with grid config and window manipulator (called after server startup)
    func configure(with config: GridConfig, windowManipulator: WindowManipulator? = nil, gridReconciler: GridReconciler? = nil, gridState: GridState? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.gridConfig = config
        if let wm = windowManipulator {
            self.windowManipulator = wm
        }
        if let gr = gridReconciler {
            self.gridReconciler = gr
        }
        if let gs = gridState {
            self.gridState = gs
        }
    }

    // MARK: - Focus Restoration

    /// Save the currently focused window so we can restore on cancel.
    /// Must be called on main thread, before show().
    func savePreviousWindow(windowID: UInt32, pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        previousWindowID = windowID
        previousWindowPID = pid
    }

    /// Restore focus to the window that was active before the picker was shown.
    private func restorePreviousWindow() {
        guard let wid = previousWindowID, let pid = previousWindowPID, let wm = windowManipulator else {
            return
        }
        _ = wm.focusWindow(pid: pid, windowID: wid)
        previousWindowID = nil
        previousWindowPID = nil
    }

    // MARK: - Show / Hide

    /// Show the picker, or toggle hide if already visible
    /// Must be called on main thread
    func show() {
        dispatchPrecondition(condition: .onQueue(.main))

        // If already visible, treat as toggle — hide
        if isVisible {
            hide()
            return
        }

        isVisible = true
        allItems = []  // Reset accumulated items for fresh show
        jlog("pick.show.begin")

        // Create window lazily — reuse across show/hide cycles
        if window == nil {
            jlog("pick.window.create")
            window = PickerWindow()
            window!.onResult = { [weak self] result in
                self?.handleResult(result)
            }
            // Observe window resign key for auto-dismiss on focus loss
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }

        // Reset window state for fresh show
        window!.resetForNewShow()
        window!.setLoading(true)

        // Activate and show
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
        window!.focusInput()
        jlog("pick.show")

        // Start async discovery
        discoveryTask = Task { [weak self] in
            await self?.discoverAndStream()
        }
    }

    /// Show the picker for an RPC caller and wait for a result.
    /// The server still executes the action; the result is returned for informational purposes.
    /// Must be called on main thread (use MainActor.run from Task context).
    func showForRPC() async -> PickerResult {
        dispatchPrecondition(condition: .onQueue(.main))

        // If already visible, cancel and return cancelled
        if isVisible {
            hide()
        }

        let result: PickerResult = await withCheckedContinuation { continuation in
            self.pendingRPCContinuation = continuation
            self.show()
        }

        return result
    }

    /// Hide the picker and cancel any in-flight discovery
    /// Must be called on main thread
    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard isVisible else { return }
        isVisible = false

        // Cancel in-flight discovery
        discoveryTask?.cancel()
        discoveryTask = nil

        // Hide window and stop spinner
        window?.orderOut(nil)
        window?.setLoading(false)

        // Resume any pending RPC continuation with cancelled
        if let continuation = pendingRPCContinuation {
            pendingRPCContinuation = nil
            continuation.resume(returning: .cancelled)
        }

        // Clear launch callback (safety net -- handleResult captures before hide)
        onLaunch = nil

        jlog("pick.hide")
    }

    // MARK: - Result Handling

    /// Called by PickerWindow.onResult callback
    private func handleResult(_ result: PickerResult) {
        isHandlingResult = true
        defer { isHandlingResult = false }

        // Capture callbacks before hide() clears them
        let continuation = pendingRPCContinuation
        pendingRPCContinuation = nil
        let capturedOnLaunch = onLaunch

        // Begin a suppression session BEFORE hide to catch all stale appActivated events.
        // endAction will be called at each exit path.
        let token = gridReconciler?.beginAction(label: "picker.result")

        // Hide first (clears UI before action executes)
        hide()

        switch result {
        case .selected(let item):
            // Record selection in history and persist immediately
            history.recordSelection(item.id)
            history.save()
            jlog("pick.selected", data: ["id": item.id])

            // Parse action from metadata
            guard let action = PickerAction.from(metadata: item.metadata) else {
                jlog("pick.err.noaction", data: ["id": item.id])
                // End suppression immediately since no action to track
                if let token = token {
                    gridReconciler?.endAction(token, syncBorders: true)
                }
                break
            }

            // Notify launch callback for launch-type actions only
            if let capturedOnLaunch = capturedOnLaunch {
                switch action {
                case .openApp, .openDir, .openChromeProfile:
                    capturedOnLaunch(action)
                case .focusWindow, .exec:
                    break
                }
            }

            // Build onPID callback for launch-type actions so the reconciler can filter phantoms.
            // NSWorkspace completion fires on an arbitrary thread; hop to main to match the
            // same thread where setPendingLaunchTarget is called (GridCommandRouter uses MainActor).
            let reconcilerRef = gridReconciler
            let onPID: ((pid_t) -> Void)? = {
                switch action {
                case .openApp, .openDir:
                    return { pid in
                        DispatchQueue.main.async {
                            reconcilerRef?.updatePendingLaunchTargetPID(pid)
                        }
                    }
                default:
                    return nil
                }
            }()

            // Clear an armed pending target when the launch fails to start (#31)
            // so it does not hijack the next unrelated window the user opens.
            let onLaunchFail: ((String) -> Void)? = {
                switch action {
                case .openApp, .openDir:
                    return { reason in
                        DispatchQueue.main.async {
                            reconcilerRef?.clearPendingLaunchTarget(reason: reason)
                        }
                    }
                default:
                    return nil
                }
            }()

            // Execute the action
            ActionExecutor.execute(action, onPID: onPID, onLaunchFail: onLaunchFail)

            // For focusWindow: update GridState in Task{} then end suppression.
            // Suppression remains active until Task runs, catching all stale events.
            if case .focusWindow(_, let windowID) = action {
                let reconciler = gridReconciler
                Task { [weak self] in
                    await self?.updateGridStateFocus(windowID)
                    if let token = token {
                        reconciler?.endAction(token, syncBorders: true)
                    }
                }
            } else {
                // Non-focus actions (openDir, openApp, exec): end suppression immediately.
                // GridState has pre-picker focus which is correct until new window appears.
                if let token = token {
                    gridReconciler?.endAction(token, syncBorders: true)
                }
            }

        case .cancelled:
            restorePreviousWindow()
            // GridState already has correct pre-picker focus. Just end suppression.
            if let token = token {
                gridReconciler?.endAction(token, syncBorders: true)
            }
        }

        // Resume RPC continuation after action execution
        if let continuation = continuation {
            continuation.resume(returning: result)
        }
    }

    // MARK: - GridState Focus Update

    /// Update GridState focus tracking to match the window we just focused via picker
    private func updateGridStateFocus(_ windowID: UInt32) async {
        guard let gridState else { return }
        guard let spaceID = await gridState.findSpaceContaining(windowID: windowID) else {
            jlog("pick.focus.nostate", data: ["wid": windowID])
            return
        }
        guard let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID) else {
            jlog("pick.focus.nocell", data: ["wid": windowID, "space": spaceID])
            return
        }
        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        let windowIndex = cellWindows.firstIndex(of: windowID) ?? 0
        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)
        jlog("pick.focus.gridstate", data: ["wid": windowID, "cell": cellID, "idx": windowIndex])
    }

    // MARK: - Async Discovery

    /// Run all PickerSources concurrently and stream items to the window as each completes.
    /// After each batch, all accumulated items are re-sorted by frecency.
    private func discoverAndStream() async {
        jlog("pick.discover.start")

        // Capture config values on main thread before entering async context
        let capturedZoxidePath = await MainActor.run { gridConfig?.zoxidePath }
        let capturedActions = await MainActor.run { gridConfig?.pickerActions ?? [] }

        // Create shared enricher for this discovery session
        let enricher = WindowEnricher()

        var sources: [PickerSource] = [
            WindowSource(enricher: enricher),
            AppSource(),
            ChromeProfileSource(),
            ZoxideSource(configuredPath: capturedZoxidePath),
        ]

        // Add action source if config has actions defined
        if !capturedActions.isEmpty {
            sources.append(ActionSource(actions: capturedActions))
        }

        await withTaskGroup(of: [PickerItem].self) { group in
            for source in sources {
                group.addTask {
                    let sid = source.id
                    jlog("pick.source.start", data: ["source": sid])
                    do {
                        let items = try await source.discover()
                        jlog("pick.source.done", data: ["source": sid, "count": "\(items.count)"])
                        return items
                    } catch {
                        jlog("pick.err.source", data: ["source": sid, "err": "\(error)"])
                        return []
                    }
                }
            }

            for await items in group {
                // Check cancellation before dispatching to main
                guard !Task.isCancelled else { break }

                // Accumulate and sort on main thread
                await MainActor.run {
                    guard isVisible, let window = window else { return }

                    // Accumulate items from this batch
                    allItems.append(contentsOf: items)

                    // Sort all accumulated items by frecency (stable — preserves order for ties)
                    history.sortByFrecency(&allItems)

                    // Replace all items in state (preserves query filter + selection)
                    window.getState().replaceItems(allItems)
                }
            }
        }

        // All sources complete — hide spinner on main thread
        await MainActor.run {
            window?.setLoading(false)
        }
    }

    // MARK: - Window Notifications

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard !isHandlingResult else { return }
        handleResult(.cancelled)
    }
}
