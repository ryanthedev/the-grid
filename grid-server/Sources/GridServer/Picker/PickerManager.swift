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

    // Grace period flag to ignore windowDidResignKey during activation policy switch
    private var isActivating = false
    private var activationGraceTimer: DispatchWorkItem?

    // History: loaded once on init, saved on each selection
    private var history: PickerHistory

    // All items accumulated during current session (for global frecency re-sort)
    private var allItems: [PickerItem] = []

    // Server config for picker sources (actions, zoxide path)
    private var config: ServerConfig?

    private init() {
        // Load history from disk on server start
        history = PickerHistory.load()
        jlog("pick.hist.loaded", data: [
            "entries": "\(history.frequency.count)",
            "previous": history.previous
        ])
    }

    /// Configure with server config (called after server startup)
    func configure(with config: ServerConfig) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.config = config
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

        // Create window lazily — reuse across show/hide cycles
        if window == nil {
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

        // Switch to .regular so we can receive key events
        // Set grace period flag before the switch to ignore the transient resign-key
        isActivating = true
        activationGraceTimer?.cancel()

        NSApp.setActivationPolicy(.regular)

        // Show and focus
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window!.focusInput()

        // End grace period after 200ms (policy switch may cause transient resign)
        let graceWork = DispatchWorkItem { [weak self] in
            self?.isActivating = false
        }
        activationGraceTimer = graceWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: graceWork)

        // Start async discovery
        discoveryTask = Task { [weak self] in
            await self?.discoverAndStream()
        }

        jlog("pick.show")
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

        // Switch back to prohibited (no Dock icon)
        NSApp.setActivationPolicy(.prohibited)

        // Resume any pending RPC continuation with cancelled
        if let continuation = pendingRPCContinuation {
            pendingRPCContinuation = nil
            continuation.resume(returning: .cancelled)
        }

        jlog("pick.hide")
    }

    // MARK: - Result Handling

    /// Called by PickerWindow.onResult callback
    private func handleResult(_ result: PickerResult) {
        // Capture pending continuation before hide() clears it
        let continuation = pendingRPCContinuation
        pendingRPCContinuation = nil

        // Hide first (clears UI before action executes)
        hide()

        switch result {
        case .selected(let item):
            // Record selection in history and persist immediately
            history.recordSelection(item.id)
            history.save()
            jlog("pick.selected", data: ["id": item.id])

            executeAction(for: item)
        case .cancelled:
            break
        }

        // Resume RPC continuation after action execution
        if let continuation = continuation {
            continuation.resume(returning: result)
        }
    }

    /// Execute the PickerAction encoded in the item's metadata
    private func executeAction(for item: PickerItem) {
        guard let action = PickerAction.from(metadata: item.metadata) else {
            jlog("pick.err.noaction", data: ["id": item.id])
            return
        }
        ActionExecutor.execute(action)
    }

    // MARK: - Async Discovery

    /// Run all PickerSources concurrently and stream items to the window as each completes.
    /// After each batch, all accumulated items are re-sorted by frecency.
    private func discoverAndStream() async {
        // Create shared enricher for this discovery session
        let enricher = WindowEnricher()

        var sources: [PickerSource] = [
            WindowSource(enricher: enricher),
            AppSource(),
            ChromeProfileSource(),
            ZoxideSource(configuredPath: config?.picker.zoxidePath),
        ]

        // Add action source if config has actions defined
        if let actions = config?.picker.actions, !actions.isEmpty {
            sources.append(ActionSource(actions: actions))
        }

        await withTaskGroup(of: [PickerItem].self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return try await source.discover()
                    } catch {
                        jlog("pick.err.source", data: ["source": source.id, "err": "\(error)"])
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
        // Skip during activation grace period — policy switch causes a transient resign
        guard !isActivating else { return }
        handleResult(.cancelled)
    }
}
