import Foundation

// MARK: - GridNotificationPriority

// Priority levels ordered low to high for sort comparisons.
enum GridNotificationPriority: String, Codable, Comparable {
    case low
    case normal
    case high
    case urgent

    // Defines the canonical ordering for < comparisons.
    private static let order: [GridNotificationPriority] = [.low, .normal, .high, .urgent]

    static func < (lhs: GridNotificationPriority, rhs: GridNotificationPriority) -> Bool {
        guard let leftIndex = order.firstIndex(of: lhs),
              let rightIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return leftIndex < rightIndex
    }
}

// MARK: - GridNotificationAction

// The three supported action types a notification can carry.
// Encoded with a "type" discriminant field plus the associated payload field.
enum GridNotificationAction: Codable {
    case focusWindow(windowID: UInt32)
    case runShellCommand(command: String)
    case openURL(url: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case windowID
        case command
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .focusWindow(let windowID):
            try container.encode("focusWindow", forKey: .type)
            try container.encode(windowID, forKey: .windowID)
        case .runShellCommand(let command):
            try container.encode("runShellCommand", forKey: .type)
            try container.encode(command, forKey: .command)
        case .openURL(let url):
            try container.encode("openURL", forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "focusWindow":
            let windowID = try container.decode(UInt32.self, forKey: .windowID)
            self = .focusWindow(windowID: windowID)
        case "runShellCommand":
            let command = try container.decode(String.self, forKey: .command)
            self = .runShellCommand(command: command)
        case "openURL":
            let url = try container.decode(String.self, forKey: .url)
            self = .openURL(url: url)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown notification action type: \(type)"
            )
        }
    }
}

// MARK: - GridNotification

// Core notification model. All fields are Codable for persistence.
// id and timestamp are immutable after creation; other state fields are mutable.
struct GridNotification: Codable, Identifiable {
    // UUID string, set at creation, never changes
    let id: String
    // Caller-defined label: "rpc", "internal", "file", "pipe"
    let source: String
    let title: String
    // Optional descriptive text; may be empty
    var body: String
    var priority: GridNotificationPriority
    // Set at creation, never changes
    let timestamp: Date
    var isRead: Bool
    var isPinned: Bool
    var isDismissed: Bool
    // nil means no action associated with this notification
    var action: GridNotificationAction?
    // Shell command that returns detail content (JSON) when executed.
    // Populated by notification sources (e.g., iMessage watcher sets this
    // to "python3 imessage-watch.py --history <handle>").
    // nil means no detail view available.
    var detailCmd: String?

    // Time-to-live in seconds. 0 = permanent (default).
    // After ttl seconds, the notification is auto-dismissed.
    var ttl: TimeInterval
    // Seconds before expiry to start warning animation. 0 = no warning.
    // The warning phase runs from (timestamp + ttl - warnBefore) until expiry.
    var warnBefore: TimeInterval

    // Number of times this notification has been upserted. Starts at 1.
    var groupCount: Int
    // When set, TTL lifecycle uses this date instead of timestamp.
    // Reset on each upsert to refresh the countdown.
    var ttlResetDate: Date?

    // Per-notification animation override. nil = use config defaults.
    var animationOverride: NotificationAnimationOverride?

    init(
        id: String = UUID().uuidString,
        source: String,
        title: String,
        body: String = "",
        priority: GridNotificationPriority = .normal,
        timestamp: Date = Date(),
        isRead: Bool = false,
        isPinned: Bool = false,
        isDismissed: Bool = false,
        action: GridNotificationAction? = nil,
        detailCmd: String? = nil,
        ttl: TimeInterval = 0,
        warnBefore: TimeInterval = 0,
        groupCount: Int = 1,
        ttlResetDate: Date? = nil,
        animationOverride: NotificationAnimationOverride? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.body = body
        self.priority = priority
        self.timestamp = timestamp
        self.isRead = isRead
        self.isPinned = isPinned
        self.isDismissed = isDismissed
        self.action = action
        self.detailCmd = detailCmd
        self.ttl = ttl
        self.warnBefore = warnBefore
        self.groupCount = groupCount
        self.ttlResetDate = ttlResetDate
        self.animationOverride = animationOverride
    }

    // Lifecycle phase of the notification based on current time.
    enum LifecyclePhase {
        case normal
        case warning
        case expired
    }

    func lifecyclePhase(at now: Date = Date()) -> LifecyclePhase {
        guard ttl > 0 else { return .normal }
        // Use ttlResetDate if set, otherwise fall back to creation timestamp
        let baseDate = ttlResetDate ?? timestamp
        let age = now.timeIntervalSince(baseDate)
        if age >= ttl { return .expired }
        if warnBefore > 0 && age >= (ttl - warnBefore) { return .warning }
        return .normal
    }

    // Seconds remaining until expiry. nil if permanent.
    func secondsRemaining(at now: Date = Date()) -> TimeInterval? {
        guard ttl > 0 else { return nil }
        // Use ttlResetDate if set, otherwise fall back to creation timestamp
        let baseDate = ttlResetDate ?? timestamp
        return max(0, ttl - now.timeIntervalSince(baseDate))
    }
}

// MARK: - NotificationAnimationOverride

// Per-notification animation override. When present, takes priority over
// YAML config presets for the phases that have non-empty lists.
// Sent via the JSON input's "animations" field.
struct NotificationAnimationOverride: Codable {
    var arrival: [String]?
    var idle: [String]?
    var warning: [String]?
    var ghost: [String]?

    // Returns animation names for a given phase.
    // Empty list means "no override for this phase" (fall through to config).
    func names(for phase: AnimationPhase) -> [String] {
        switch phase {
        case .arrival: return arrival ?? []
        case .idle: return idle ?? []
        case .warning: return warning ?? []
        case .ghost: return ghost ?? []
        }
    }
}

// MARK: - GridNotificationFilter

// Criteria for querying the store. All predicates are ANDed.
struct GridNotificationFilter {
    var includeRead: Bool = true
    // Dismissed notifications are hidden by default
    var includeDismissed: Bool = false
    var includePinned: Bool = true
    // nil = all sources; non-nil = only notifications from these sources
    var sources: [String]? = nil
    // nil = all priorities; non-nil = only notifications at or above this level
    var minPriority: GridNotificationPriority? = nil
    // nil = no text filter; non-nil matches title or body case-insensitively
    var searchText: String? = nil

    // Active notifications: not dismissed, all else included
    static var active: GridNotificationFilter { GridNotificationFilter() }

    // All notifications including dismissed
    static var all: GridNotificationFilter { GridNotificationFilter(includeDismissed: true) }
}

// MARK: - GridNotificationStoreData

// Persisted container. Mirrors the GridRuntimeStateData pattern.
struct GridNotificationStoreData: Codable {
    // Schema version for forward-compatible migration
    var version: Int = 1
    var notifications: [GridNotification] = []
    // Preserves insertion order for stable list rendering
    var orderedIDs: [String] = []
    var lastUpdated: Date = Date()
}
