import Foundation

// MARK: - TmuxStatusWatcher

// Watches the tmux status JSON file for changes and delivers decoded TmuxStatusData
// to callers via the onChange callback. Mirrors AnimationConfigWatcher exactly:
// O_EVTONLY + DispatchSource, serial queue, retry on missing file, callback on main thread.
//
// This class is the barricade boundary for external cross-process JSON input.
// Decode failures are logged and skipped; onChange is only called on success.
// The watcher retains the last successfully decoded value and re-emits it on the
// next successful decode — callers never see partial or malformed data.
//
// Atomic-rename handling: tmux-status.json is written via temp+rename. The watcher
// handles .delete/.rename events by tearing down and reopening the file descriptor,
// mirroring the AnimationConfigWatcher.handleChange pattern.
final class TmuxStatusWatcher {

    // Path to the status file to watch.
    private let path: String

    // Serial queue for all fd/source operations.
    private let queue = DispatchQueue(label: "com.thegrid.notify.tmuxstatus")

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var isRunning: Bool = false

    // Callback invoked on the main thread when a new value is successfully decoded.
    var onChange: ((TmuxStatusData) -> Void)?

    init(path: String) {
        self.path = path
    }

    // Convenience initializer using the canonical XDG state path.
    convenience init() {
        self.init(path: "\(XDG.stateHome)/thegrid/tmux-status.json")
    }

    // Start watching the file. If the file does not yet exist, retries every 5 seconds.
    // Safe to call multiple times — second call is a no-op.
    func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
        }
        queue.async { [weak self] in
            self?.watchFile()
        }
        jlog("tmux.watcher.start", data: ["path": path])
    }

    // Stop watching and release all OS resources.
    // Safe to call multiple times — idempotent.
    func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            tearDown()
        }
        jlog("tmux.watcher.stop")
    }

    // MARK: - Private

    private func watchFile() {
        guard isRunning else { return }

        let openFD = open(path, O_RDONLY | O_EVTONLY)
        guard openFD >= 0 else {
            // File does not exist yet — retry after a delay.
            jlog("tmux.watcher.nofile", data: ["path": path])
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.watchFile()
            }
            return
        }
        fd = openFD

        let events: DispatchSource.FileSystemEvent = [.write, .delete, .rename]
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: events,
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleChange()
        }
        src.resume()
        source = src

        // Parse on startup so the caller gets data immediately.
        reloadAndNotify()

        jlog("tmux.watcher.watch", data: ["path": path])
    }

    private func handleChange() {
        guard isRunning else { return }
        let events = source?.data ?? 0
        let eventMask = DispatchSource.FileSystemEvent(rawValue: events)

        if eventMask.contains(.delete) || eventMask.contains(.rename) {
            // File was atomically replaced (temp + rename).
            // Tear down the old fd and reopen against the new inode.
            tearDown()
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.reloadAndNotify()
                self.watchFile()
            }
        } else {
            // .write event: file was modified in place.
            reloadAndNotify()
        }
    }

    // Attempt to decode the file. On success, deliver to onChange on main thread.
    // On failure, log a warn/err event and retain the prior value (implicit: callers
    // only see onChange calls, never decode errors).
    private func reloadAndNotify() {
        guard isRunning else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoded = try JSONDecoder().decode(TmuxStatusData.self, from: data)
            let value = decoded
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onChange?(value)
            }
            jlog("tmux.watcher.reload", data: [
                "sessions": decoded.sessions.count,
                "generatedAt": decoded.generatedAt
            ])
        } catch let error as DecodingError {
            jlog("warn.tmux.watcher.decode", msg: "JSON decode failed, retaining prior value",
                 data: ["err": "\(error)", "path": path])
        } catch {
            jlog("err.tmux.watcher.read", msg: "file read failed",
                 data: ["err": "\(error)", "path": path])
        }
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
