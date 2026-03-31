import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NotificationPanelWindow?
    private var viewModel: NotificationPanelViewModel?
    private var store: NotificationStore?
    private var fileWatcher: NotificationFileWatcher?

    // Retain signal source references to prevent deallocation
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

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

    func applicationWillTerminate(_ notification: Notification) {
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
