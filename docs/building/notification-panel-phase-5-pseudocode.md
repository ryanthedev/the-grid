# Pseudocode: Phase 5 - Configuration and polish

## Files to Create/Modify

- MODIFY `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- add `GridNotificationsYAML`, `GridNotificationsConfig`, `parseNotifications(from:)` helper, and `notifications` property
- MODIFY `grid-server/Sources/GridServer/Notifications/NotificationStore.swift` -- add `trim(to maxCount:)` method
- MODIFY `grid-server/Sources/GridServer/main.swift` -- wire `gridConfig.onReload`, change `let` to `var` for handler/watcher, apply config on startup

## Design Notes

### Approaches Considered

1. **Approach A: Lazy parse (store raw dict, parse on demand)**
   - Interface: `gridConfig.notificationsDict["theme"]?["background"]`
   - Pro: Minimal code in GridConfig
   - Con: Leaks parse logic to callers; mismatches every other GridConfig section

2. **Approach B: Eager parse to typed struct (CHOSEN)**
   - Interface: `gridConfig.notifications.theme`, `gridConfig.notifications.eventRules`
   - Pro: Consistent with all other GridConfig sections (`settings`, `spaces`, `appRules`). Callers get typed values. Single parse call at load time. GridConfig hides all YAML detail.
   - Con: Slightly more struct definitions

3. **Approach C: Separate `NotificationsConfigManager` singleton**
   - Pro: Single place
   - Con: Shallow module over thin functionality; adds abstraction without depth

**Choice: Approach B.** Every other GridConfig section uses this pattern. The interface is simple (`gridConfig.notifications`) and the YAML details are hidden.

### Information Hiding
- `GridNotificationsYAML` is a private `Codable` struct used only inside `GridConfig.swift`
- Callers only see `GridNotificationsConfig` (runtime typed struct), accessed via `gridConfig.notifications`
- Hot-reload logic lives entirely in `main.swift`'s `onReload` closure; GridConfig knows nothing about notification singletons

### Hot-Reload Design
`NotificationEventHandler` and `NotificationFileWatcher` are immutable after init (config is a let). Hot-reload must replace them. The `onReload` closure in `main.swift` captures these as `var` references, stops old instances, creates new ones. `NotificationPanelManager.configure(theme:)` updates the live theme in-place (the existing design supports this).

---

## Pseudocode

### GridConfig.swift -- additions only

```
// MARK: - YAML struct (private, decode-only, not exposed to callers)
// Used only inside parseNotifications(from:). All YAML field names match
// the config.yaml key names exactly.

private struct NotificationsYAML: Codable
    // notifications:
    //   theme:
    //     background: "#121212"
    //     accent: "#FF9500"
    //     ... (all NotificationPanelTheme fields, by their Swift names)
    var theme: [String: String]?

    // notifications:
    //   max_count: 200
    var maxCount: Int?

    // notifications:
    //   event_rules:
    //     ev.win.create:
    //       title: "Window Created"
    //       body: "{event}"      (optional)
    //       priority: "normal"   (optional, default "normal")
    var eventRules: [String: EventRuleYAML]?

    // notifications:
    //   file_watcher:
    //     path: "~/.local/state/thegrid/notify.pipe"
    //     source_label: "pipe"   (optional, default "pipe")
    var fileWatcher: FileWatcherYAML?

    enum CodingKeys: String, CodingKey
        case theme
        case maxCount = "max_count"
        case eventRules = "event_rules"
        case fileWatcher = "file_watcher"

private struct EventRuleYAML: Codable
    var title: String
    var body: String?
    var priority: String?

private struct FileWatcherYAML: Codable
    var path: String?
    var sourceLabel: String?
    enum CodingKeys: String, CodingKey
        case path
        case sourceLabel = "source_label"

// MARK: - Runtime struct (public, typed, no YAML details)
// Callers access via gridConfig.notifications

struct GridNotificationsConfig: Sendable
    // Keyed by event logInfo name, e.g. "ev.win.create"
    var eventRules: [String: EventNotificationRule] = [:]
    // Empty path = watcher disabled; expanded tilde path otherwise
    var watcherPath: String = ""
    var watcherSourceLabel: String = "pipe"
    // Max stored notifications; 0 = unlimited
    var maxCount: Int = 0
    // Raw hex dict passed directly to NotificationPanelTheme.init(from:)
    var themeColors: [String: String] = [:]


// MARK: - In GridConfig class

// New property (alongside existing settings, layouts, spaces, appRules)
private(set) var notifications: GridNotificationsConfig = GridNotificationsConfig()


// MARK: - In GridConfig.load() -- add this call alongside other parse* calls
// After parseServerFields(from: merged):
parseNotifications(from: merged)


// MARK: - New private method

private func parseNotifications(from dict: [String: Any])
    // Extract the notifications: top-level key
    guard let raw = dict["notifications"] as? [String: Any] else
        // No notifications section -- reset to defaults (supports removing config)
        notifications = GridNotificationsConfig()
        return

    // Re-serialize to YAML string and decode via YAMLDecoder for correct type handling
    // (consistent with parseLayouts, parseAppRules, etc.)
    do
        let yamlStr = try Yams.dump(object: raw)
        let decoded = try YAMLDecoder().decode(NotificationsYAML.self, from: yamlStr)

        var config = GridNotificationsConfig()

        // Theme colors: pass raw [String: String] dict directly to NotificationPanelTheme
        if let themeDict = decoded.theme
            config.themeColors = themeDict

        // Max count
        if let mc = decoded.maxCount, mc > 0
            config.maxCount = mc

        // Event rules: map from YAML structs to Swift value types
        if let rulesRaw = decoded.eventRules
            for (eventName, ruleYAML) in rulesRaw
                let priority = GridNotificationPriority(rawValue: ruleYAML.priority ?? "normal")
                    ?? .normal
                config.eventRules[eventName] = EventNotificationRule(
                    title: ruleYAML.title,
                    body: ruleYAML.body ?? "",
                    priority: priority
                )

        // File watcher path: expand tilde
        if let fw = decoded.fileWatcher
            config.watcherPath = expandTilde(fw.path ?? "")
            config.watcherSourceLabel = fw.sourceLabel ?? "pipe"

        notifications = config
        jlog("grid.cfg.notifications", data: [
            "event_rules": config.eventRules.count,
            "watcher_path": config.watcherPath,
            "max_count": config.maxCount
        ])

    catch
        // Log and keep defaults -- malformed notifications section should not crash server
        jlog("err.grid.cfg.notifications", msg: "failed to parse", data: ["err": "\(error)"])
        notifications = GridNotificationsConfig()
```

---

### NotificationStore.swift -- add trim method

```
// MARK: - Trim

// Removes the oldest non-pinned notifications beyond maxCount.
// Pinned notifications are always preserved.
// Called after add() when a maxCount is configured.
// Returns count of removed notifications.
@discardableResult
func trim(to maxCount: Int) -> Int
    guard maxCount > 0 else { return 0 }

    // Build ordered list of non-pinned IDs (oldest first = front of orderedIDs)
    let unpinnedIDs = orderedIDs.filter { byID[$0]?.isPinned == false }

    let excess = unpinnedIDs.count - maxCount
    guard excess > 0 else { return 0 }

    // Remove oldest unpinned notifications (first in insertion order)
    let toRemove = Array(unpinnedIDs.prefix(excess))
    for id in toRemove
        byID.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }

    if !toRemove.isEmpty
        markDirty()

    return toRemove.count
```

---

### main.swift -- wiring changes

```
// MARK: - Change let to var for hot-reload replacement

// Phase 4 had:
//   let notificationEventConfig = NotificationEventConfig()
//   let notificationEventHandler = NotificationEventHandler(...)
//   let notificationWatcherConfig = NotificationWatcherConfig()
//   let notificationFileWatcher = NotificationFileWatcher(...)

// Phase 5 changes these to var and reads initial config from gridConfig:

var notificationEventHandler = NotificationEventHandler(
    store: NotificationStore.shared,
    config: NotificationEventConfig()   // start with empty; will be replaced once gridConfig loads
)

var notificationFileWatcher = NotificationFileWatcher(
    store: NotificationStore.shared,
    config: NotificationWatcherConfig() // empty path = disabled until config loads
)
notificationFileWatcher.start()


// MARK: - Wire gridConfig.onReload after gridConfig initialization

// After the Task { try await gridConfig.load() } block, assign the reload callback:
gridConfig.onReload = {
    // Must dispatch to main because NotificationPanelManager is @MainActor
    DispatchQueue.main.async {
        let notifConfig = gridConfig.notifications

        // 1. Update panel theme (in-place, no window recreation needed)
        let theme = notifConfig.themeColors.isEmpty
            ? .default
            : NotificationPanelTheme(from: notifConfig.themeColors)
        NotificationPanelManager.shared.configure(theme: theme)

        // 2. Replace event handler with new config
        Task {
            await notificationEventHandler.stop()
            notificationEventHandler = NotificationEventHandler(
                store: NotificationStore.shared,
                config: NotificationEventConfig(rules: notifConfig.eventRules)
            )
        }

        // 3. Replace file watcher if path changed
        notificationFileWatcher.stop()
        notificationFileWatcher = NotificationFileWatcher(
            store: NotificationStore.shared,
            config: NotificationWatcherConfig(
                path: notifConfig.watcherPath,
                sourceLabel: notifConfig.watcherSourceLabel
            )
        )
        notificationFileWatcher.start()

        jlog("notify.cfg.reloaded")
    }
}


// MARK: - Apply initial config once gridConfig finishes loading
// The existing Task { try await gridConfig.load() } already calls onReload? indirectly
// via reload(). However, the initial load() does NOT call onReload -- it only calls it
// on subsequent reloads. So we need to apply initial notification config after first load.

// Inside the existing Task { try await gridConfig.load() } block, after load():
// Note: gridConfig.onReload must be set BEFORE this Task runs.
// The assignment above ensures it is set before gridConfig.load() is called.
// After load(), also apply initial config:

Task {
    do {
        try await gridConfig.load()
        jlog("grid.cfg.ready")

        // Apply initial notification config from the loaded config
        let notifConfig = gridConfig.notifications
        if !notifConfig.themeColors.isEmpty
            let theme = NotificationPanelTheme(from: notifConfig.themeColors)
            await MainActor.run { NotificationPanelManager.shared.configure(theme: theme) }

        // Replace event handler if rules are configured
        if !notifConfig.eventRules.isEmpty
            await notificationEventHandler.stop()
            notificationEventHandler = NotificationEventHandler(
                store: NotificationStore.shared,
                config: NotificationEventConfig(rules: notifConfig.eventRules)
            )

        // Replace file watcher if path is configured
        if !notifConfig.watcherPath.isEmpty
            notificationFileWatcher.stop()
            notificationFileWatcher = NotificationFileWatcher(
                store: NotificationStore.shared,
                config: NotificationWatcherConfig(
                    path: notifConfig.watcherPath,
                    sourceLabel: notifConfig.watcherSourceLabel
                )
            )
            notificationFileWatcher.start()

    catch
        jlog("err.grid.cfg", data: ["err": "\(error)"])
}


// MARK: - Update signal handlers to use var references
// Shutdown signal handlers already reference notificationFileWatcher and notificationEventHandler.
// Since these are now var, the closures must capture them by reference (they already do via
// self-capture; in a free function main.swift, closures capture the var binding directly).
// No structural change needed -- the closures will use the current value of the vars at
// the time they execute.
```

---

### YAML schema (example config.yaml addition)

```yaml
notifications:
  # Theme colors (hex strings, any omitted key falls back to dark theme default)
  theme:
    background: "#121212"
    surface: "#1E1E1E"
    surfaceSelected: "#2A2A2A"
    textPrimary: "#BFBFBF"
    textSecondary: "#808080"
    textTertiary: "#5A5A5A"
    accent: "#FF9500"
    accentDim: "#CC7700"
    urgent: "#FF3B30"
    pinned: "#FFD60A"
    border: "#333333"
    filterBackground: "#232323"

  # Maximum stored notifications (0 = unlimited)
  max_count: 200

  # Event-driven notifications: map from logInfo event name to rule
  event_rules:
    "ev.win.create":
      title: "Window Created"
      body: "{event}"
      priority: "normal"

  # File/pipe watcher source
  file_watcher:
    path: "~/.local/state/thegrid/notify.pipe"
    source_label: "pipe"
```

---

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (Approach B chosen over A and C; rationale documented)
- [ ] Ready for implementation
