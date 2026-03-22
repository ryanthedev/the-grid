import Foundation

// Minimal config structs for Phase 4 notification sources.
// Phase 5 will parse these from the notifications: YAML section.
// Defined here as value types with sensible defaults so sources work
// without any config file changes.

// MARK: - EventNotificationRule

// Maps a single grid event type to a notification descriptor.
// The {event} token in title/body is replaced with the event's logInfo name.
struct EventNotificationRule {
    // Human-readable title for the generated notification.
    // Supports substitution token: {event} -> the event name (e.g. "ev.win.create")
    let title: String
    // Optional body text. Supports the same {event} token.
    let body: String
    let priority: GridNotificationPriority

    init(title: String, body: String = "", priority: GridNotificationPriority = .normal) {
        self.title = title
        self.body = body
        self.priority = priority
    }
}

// MARK: - NotificationEventConfig

// Configuration for the event-driven notification source.
// Empty rules map means no event-driven notifications (opt-in, not opt-out).
struct NotificationEventConfig {
    // Map from StateEvent logInfo name to a notification rule.
    // Key is the event's logInfo string, e.g. "ev.win.create", "ev.focus", "ev.app.launch"
    let rules: [String: EventNotificationRule]

    init(rules: [String: EventNotificationRule] = [:]) {
        self.rules = rules
    }
}

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
