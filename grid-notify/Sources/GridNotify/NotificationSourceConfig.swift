import Foundation

// MARK: - NotificationWatcherConfig

// Configuration for the file/pipe notification source.
// Empty path means the watcher is disabled.
struct NotificationWatcherConfig {
    // Path to watch. May be a regular file or a named pipe (FIFO).
    // Empty string means watcher is disabled.
    let path: String
    // Source label written into GridNotification.source for notifications from this watcher.
    let sourceLabel: String

    init(path: String = "", sourceLabel: String = "pipe") {
        self.path = path
        self.sourceLabel = sourceLabel
    }
}
