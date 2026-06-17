import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NotificationPanelWindow?
    private var viewModel: NotificationPanelViewModel?
    private var store: NotificationStore?
    private var fileWatcher: NotificationFileWatcher?
    private var scriptManager: ScriptManager?
    private var animConfigWatcher: AnimationConfigWatcher?

    // Retain signal source references to prevent deallocation
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    // MARK: - Tmux dashboard subsystem (nil when config.tmux.enabled == false)
    private var tmuxDashboardWindow: TmuxDashboardWindow?
    private var tmuxViewModel: TmuxDashboardViewModel?
    private var tmuxWatcher: TmuxStatusWatcher?
    private var tmuxDriver: TmuxStatusDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log startup
        jlog("notify.start", data: [
            "ver": GridNotifyVersion,
            "commit": GridNotifyCommit
        ])
        // Set activation policy to .regular (visible app)
        NSApp.setActivationPolicy(.regular)

        // Load config
        let config = loadNotifyConfig()
        jlog("notify.cfg.loaded", data: [
            "pipe_path": config.pipePath,
            "max_count": config.maxCount
        ])

        // Load theme
        let theme: NotificationPanelTheme
        if config.themeColors.isEmpty {
            theme = .default
        } else {
            theme = NotificationPanelTheme(from: config.themeColors)
        }

        // Create and load store
        let store = NotificationStore()
        self.store = store
        Task {
            await store.load()
            jlog("notify.store.ready")

            // Enforce max count on startup
            if config.maxCount > 0 {
                await store.trim(to: config.maxCount)
            }
        }

        // Create view model
        let vm = NotificationPanelViewModel(store: store, theme: theme)
        self.viewModel = vm

        // Initialize animation engine
        AnimationRegistry.shared.registerBuiltins()
        let animConfig = loadAnimationConfigFromYAML()
        vm.updateAnimationConfig(animConfig)

        // Start hot-reload watcher for animation config
        let animWatcher = AnimationConfigWatcher()
        animWatcher.onConfigChange = { [weak vm] config in
            vm?.updateAnimationConfig(config)
            jlog("notify.animcfg.applied")
        }
        animWatcher.start()
        self.animConfigWatcher = animWatcher

        // Create and show window
        let window = NotificationPanelWindow(viewModel: vm)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Start file watcher if pipe path is configured
        if !config.pipePath.isEmpty {
            let watcherConfig = NotificationWatcherConfig(
                path: config.pipePath,
                sourceLabel: config.pipeSourceLabel
            )
            let watcher = NotificationFileWatcher(store: store, config: watcherConfig)
            watcher.onNotification = { [weak vm] in
                vm?.refreshNotifications()
            }
            watcher.start()
            self.fileWatcher = watcher
        }

        // Start managed scripts (e.g., iMessage watcher)
        let enabledScripts = config.scripts.filter { $0.enabled }
        if !enabledScripts.isEmpty {
            let mgr = ScriptManager()
            for script in enabledScripts {
                mgr.register(ScriptManager.ScriptConfig(
                    name: script.name,
                    path: script.path,
                    arguments: script.arguments,
                    restartDelay: script.restartDelay
                ))
            }
            mgr.startAll()
            self.scriptManager = mgr
            jlog("notify.scripts.started", data: ["count": enabledScripts.count])
        }

        // Wire the tmux dashboard subsystem when the feature is enabled.
        // When disabled, no observers, no driver, no window — zero overhead.
        if config.tmux.enabled {
            setupTmuxDashboard(config: config.tmux, theme: theme)
        }

        // Listen for toggle notification from grid-server / BFD
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleToggle),
            name: NSNotification.Name("com.thegrid.notify.toggle"),
            object: nil
        )

        // Set up signal handling for graceful shutdown
        setupSignalHandlers()

        jlog("notify.ready")
    }

    @objc private func handleToggle(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.isVisible == true, NSApp.isActive {
                // Hide: order out and switch to accessory
                self.window?.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
                jlog("notify.toggle.hide")
            } else {
                // Show: switch to regular and bring forward
                NSApp.setActivationPolicy(.regular)
                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.viewModel?.refreshNotifications()
                jlog("notify.toggle.show")
            }
        }
    }

    // MARK: - Tmux dashboard setup

    // Sprouted method: creates the tmux dashboard components and registers
    // the two DistributedNotification observers. Called only when tmux is enabled.
    // Mirrors the existing notify-panel wiring (window + vm + watcher + observers).
    @MainActor
    private func setupTmuxDashboard(config: NotifyConfig.Tmux, theme: NotificationPanelTheme) {
        let vm = TmuxDashboardViewModel(theme: theme)
        let dashWindow = TmuxDashboardWindow(viewModel: vm)
        let watcher = TmuxStatusWatcher()
        let driver = TmuxStatusDriver(config: config)

        // Live update: watcher dispatches onChange on the main queue; hop to
        // MainActor to satisfy @MainActor isolation on TmuxDashboardViewModel.load(_:).
        watcher.onChange = { [weak vm] data in
            Task { @MainActor in
                vm?.load(data)
            }
        }

        // Refresh button path: in-view button → viewModel.onRefreshRequested → driver.refreshNow().
        vm.onRefreshRequested = { [weak driver] in
            driver?.refreshNow()
        }

        self.tmuxViewModel = vm
        self.tmuxDashboardWindow = dashWindow
        self.tmuxWatcher = watcher
        self.tmuxDriver = driver

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleTmuxToggle),
            name: NSNotification.Name("com.thegrid.tmux.toggle"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleTmuxRefresh),
            name: NSNotification.Name("com.thegrid.tmux.refresh"),
            object: nil
        )

        jlog("tmux.setup.done", data: [
            "interval": config.interval,
            "repoDir": config.repoDir,
        ])
    }

    // MARK: - Tmux notification handlers

    // Handles com.thegrid.tmux.toggle: show→start or hide→stop.
    // Uses TmuxDashboardLifecyclePolicy to decide the action (pure, testable).
    @objc private func handleTmuxToggle(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isVisible = self.tmuxDashboardWindow?.isVisible == true
            let action = TmuxDashboardLifecyclePolicy.action(windowVisible: isVisible)
            switch action {
            case .showAndStart:
                NSApp.setActivationPolicy(.regular)
                self.tmuxDashboardWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // start() is idempotent; watcher.start() triggers an immediate reload.
                self.tmuxWatcher?.start()
                self.tmuxDriver?.start()
                jlog("tmux.toggle.show")
            case .hideAndStop:
                self.tmuxDashboardWindow?.orderOut(nil)
                // Stop the driver to prevent further claude spawns while hidden.
                self.tmuxDriver?.stop()
                self.tmuxWatcher?.stop()
                jlog("tmux.toggle.hide")
            }
        }
    }

    // Handles com.thegrid.tmux.refresh: triggers an immediate driver run.
    // Does not change window visibility.
    @objc private func handleTmuxRefresh(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tmuxDriver?.refreshNow()
            jlog("tmux.refresh.requested")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the tmux subsystem first: watcher before driver so no
        // new file-change callbacks arrive after the driver releases the lock.
        tmuxWatcher?.stop()
        tmuxDriver?.stop()
        animConfigWatcher?.stop()
        scriptManager?.stopAll()
        fileWatcher?.stop()
        // Flush store synchronously.
        // applicationWillTerminate runs on main thread so we use a semaphore
        // to wait for the actor method.
        let store = self.store
        let sem = DispatchSemaphore(value: 0)
        Task {
            await store?.flush()
            sem.signal()
        }
        sem.wait()
        jlog("notify.shutdown")
    }

    // Re-show window if user clicks Dock icon while app is already running
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func setupSignalHandlers() {
        let signalQueue = DispatchQueue(label: "com.thegrid.notify.signals")

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigint.setEventHandler { [weak self] in
            jlog("notify.sig.int")
            self?.scriptManager?.stopAll()
            self?.fileWatcher?.stop()
            let store = self?.store
            Task {
                await store?.flush()
                jlog("notify.shutdown.done")
                Darwin.exit(0)
            }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)
        self.sigintSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigterm.setEventHandler { [weak self] in
            jlog("notify.sig.term")
            self?.scriptManager?.stopAll()
            self?.fileWatcher?.stop()
            let store = self?.store
            Task {
                await store?.flush()
                jlog("notify.shutdown.done")
                Darwin.exit(0)
            }
        }
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)
        self.sigtermSource = sigterm
    }
}
