import Foundation
import AppKit

/// Main orchestrator for the BFD hotkey daemon
class BFDManager: NSObject {
    private let keyHandler: BFDKeyHandler
    private var executor: BFDExecutor?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var config: BFDConfig?
    private let configPath: String
    private var pendingReload: DispatchWorkItem?

    init(configPath: String = BFDConfig.defaultPath) {
        self.configPath = configPath
        self.keyHandler = BFDKeyHandler()
        super.init()

        keyHandler.onHotkeyTriggered = { [weak self] spec, def in
            self?.executor?.executeAsync(hotkey: spec, command: def.run)
        }
    }

    deinit {
        stop()
    }

    /// Start the hotkey daemon
    func start() async -> Bool {
        // Load config using XDG resolution (supports .local.yaml overlays)
        do {
            let loadedConfig = try await BFDConfig.load()
            self.config = loadedConfig
            self.executor = BFDExecutor(config: loadedConfig)
            keyHandler.updateConfig(loadedConfig)
            JSONLogger.shared.log("bfd.init", data: ["path": configPath])
        } catch {
            JSONLogger.shared.log("bfd.err.config", data: ["err": "\(error)", "path": configPath])
            // Start without config - will be loaded on reload
            self.config = BFDConfig()
            self.executor = BFDExecutor(config: BFDConfig())
        }

        // Start key handler
        guard keyHandler.start() else {
            Task {
                JSONLogger.shared.log("bfd.err.start", data: [:])
            }
            return false
        }

        // Start config watcher
        startConfigWatcher()

        // Listen for sleep/wake to recover event tap
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        return true
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Delay slightly — event tap may not be ready immediately after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.handleWake()
        }
    }

    /// Stop the hotkey daemon
    func stop() {
        stopConfigWatcher()
        keyHandler.stop()

        Task {
            JSONLogger.shared.log("bfd.stop", data: [:])
        }
    }

    /// Restart the event tap after sleep/wake
    func handleWake() {
        keyHandler.restart()
    }

    /// Reload configuration
    func reload() async {
        do {
            let loadedConfig = try await BFDConfig.load()
            self.config = loadedConfig
            self.executor = BFDExecutor(config: loadedConfig)
            keyHandler.updateConfig(loadedConfig)
            JSONLogger.shared.log("bfd.reload", data: ["path": configPath])
        } catch {
            JSONLogger.shared.log("bfd.err.reload", data: ["err": "\(error)"])
        }
    }

    // MARK: - Private

    private func startConfigWatcher() {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        let fd = open(expandedPath, O_EVTONLY)
        guard fd >= 0 else { return }

        configWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        configWatcher?.setEventHandler { [weak self] in
            guard let self = self else { return }

            // Cancel any pending reload
            self.pendingReload?.cancel()

            // Schedule new reload with debounce
            let workItem = DispatchWorkItem { [weak self] in
                Task {
                    await self?.reload()
                }
            }
            self.pendingReload = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        configWatcher?.setCancelHandler {
            close(fd)
        }

        configWatcher?.resume()
    }

    private func stopConfigWatcher() {
        configWatcher?.cancel()
        configWatcher = nil
    }
}
