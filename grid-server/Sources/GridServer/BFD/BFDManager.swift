import Foundation

/// Main orchestrator for the BFD hotkey daemon
class BFDManager {
    private let keyHandler: BFDKeyHandler
    private var executor: BFDExecutor?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var config: BFDConfig?
    private let configPath: String

    init(configPath: String = BFDConfig.defaultPath) {
        self.configPath = configPath
        self.keyHandler = BFDKeyHandler()

        keyHandler.onHotkeyTriggered = { [weak self] spec, def in
            self?.executor?.executeAsync(hotkey: spec, command: def.run)
        }
    }

    deinit {
        stop()
    }

    /// Start the hotkey daemon
    func start() -> Bool {
        // Load config
        do {
            let loadedConfig = try BFDConfig.load(from: configPath)
            self.config = loadedConfig
            self.executor = BFDExecutor(config: loadedConfig)
            keyHandler.updateConfig(loadedConfig)

            Task {
                await EventLog.shared.log("bfd.init", ["path": configPath])
            }
        } catch {
            Task {
                await EventLog.shared.log("bfd.err.config", ["err": "\(error)", "path": configPath])
            }
            // Start without config - will be loaded on reload
            self.config = BFDConfig()
            self.executor = BFDExecutor(config: BFDConfig())
        }

        // Start key handler
        guard keyHandler.start() else {
            Task {
                await EventLog.shared.log("bfd.err.start", [:])
            }
            return false
        }

        // Start config watcher
        startConfigWatcher()

        return true
    }

    /// Stop the hotkey daemon
    func stop() {
        stopConfigWatcher()
        keyHandler.stop()

        Task {
            await EventLog.shared.log("bfd.stop", [:])
        }
    }

    /// Reload configuration
    func reload() {
        do {
            let loadedConfig = try BFDConfig.load(from: configPath)
            self.config = loadedConfig
            self.executor = BFDExecutor(config: loadedConfig)
            keyHandler.updateConfig(loadedConfig)

            Task {
                await EventLog.shared.log("bfd.reload", ["path": configPath])
            }
        } catch {
            Task {
                await EventLog.shared.log("bfd.err.reload", ["err": "\(error)"])
            }
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
            // Debounce rapid file changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.reload()
            }
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
