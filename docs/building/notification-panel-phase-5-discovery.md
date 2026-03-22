# Discovery: Phase 5 - Configuration and polish

## Files Found

### Primary file to modify
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- EXISTS. Full config loading pattern confirmed. Deep-merge via `[String: Any]` dictionary, then each section parsed by a private `parse*` helper. `onReload` callback defined at line 255 but NOT yet wired in `main.swift`. Hot-reload fires `onReload?()` after each successful `load()`.
- `grid-server/Sources/GridServer/main.swift` -- EXISTS. Phase 4 stubbed notification wiring with empty configs at lines 132-149. `onReload` is not assigned anywhere; this is the gap Phase 5 closes.

### Notification files that receive the parsed config
- `grid-server/Sources/GridServer/Notifications/NotificationSourceConfig.swift` -- EXISTS. Defines `EventNotificationRule`, `NotificationEventConfig`, `NotificationWatcherConfig` as value types. Has Phase 5 TODO comment: "Phase 5 will parse these from the notifications: YAML section."
- `grid-server/Sources/GridServer/Notifications/NotificationPanelTheme.swift` -- EXISTS. `init(from dictionary: [String: String])` already implemented and waiting to be called with YAML-parsed data. Comment: "Phase 5 replaces colors from YAML config at init time."
- `grid-server/Sources/GridServer/Notifications/NotificationPanelManager.swift` -- EXISTS. `configure(theme:)` method ready at line 26. Can be called again after hot-reload to update live theme.
- `grid-server/Sources/GridServer/Notifications/NotificationEventHandler.swift` -- EXISTS. Reads its config at init time; config is immutable. Hot-reload must stop old handler and create a new one.
- `grid-server/Sources/GridServer/Notifications/NotificationFileWatcher.swift` -- EXISTS. `stop()` and `start()` methods available. Hot-reload must stop old watcher and start a new one with new config.
- `grid-server/Sources/GridServer/Notifications/NotificationStore.swift` -- EXISTS. No changes needed; max count could be enforced here but plan flags it as low-priority.
- `grid-server/Sources/GridServer/Notifications/Notification.swift` -- EXISTS. `GridNotification` struct. No changes needed.

### No CLI notify command
The plan's "done when" list includes "CLI push -> notification appears". The CLI `@notify` command was wired in Phase 3 via the GridCommandRouter/RPC path. The Go CLI has no `notify` binary -- `thegrid notify push` routes through the existing RPC socket, which was Phase 3's deliverable. Confirmed: no `.go` notify file exists. This is not a gap; CLI push already works via RPC.

## Current State

Phases 1-4 are complete and integrated. The notification system is fully functional via RPC/CLI. Phase 5 is the config wiring layer only:

- `NotificationPanelTheme` has `init(from dictionary: [String: String])` -- just needs the YAML dict
- `NotificationEventConfig` and `NotificationWatcherConfig` are instantiated with empty/default values in main.swift with explicit TODO comments pointing to Phase 5
- `GridConfig.onReload` callback exists but is unassigned; it fires after every successful reload
- `NotificationPanelManager.configure(theme:)` is ready for hot-reload calls
- `NotificationEventHandler` and `NotificationFileWatcher` support stop/start lifecycle

## Gaps vs Plan

### Gap 1: `GridConfig` has no `notifications:` parsing
The `GridConfig.load()` method calls `parseSettings()`, `parseLayouts()`, etc. There is no `parseNotifications()` call. This is the primary work of Phase 5.

**Impact:** Nothing is actually different between current state and what needs to be built. This is pure additive work.

### Gap 2: Hot-reload for notification sources requires lifecycle management
`NotificationEventHandler` captures its `NotificationEventConfig` at init time. It cannot be updated in-place. Similarly, `NotificationFileWatcher` must stop and restart if the watched path changes.

**Resolution:** The `onReload` closure in `main.swift` will handle this: unregister the old handler, create a new one with updated config, stop the old watcher, start a new one. References need to be `var` not `let` in the main scope.

### Gap 3: `max_notifications` and auto-dismiss rules
The plan's scope lists "max notifications, auto-dismiss rules" in the YAML section. These are useful but not required for the "done when" criteria (which only mentions theme, event filters, file paths, and end-to-end flow). The NotificationStore has no max-count enforcement today.

**Resolution:** Implement `maxCount` in the YAML parse and honor it in `NotificationStore.add()` via a trim call. Auto-dismiss (time-based) is more complex; defer to a post-Phase-5 enhancement unless trivial to add.

### Gap 4: `onReload` is wired in GridConfig but not called anywhere in main.swift
The `gridConfig.onReload = { ... }` assignment is missing from main.swift. This is the connection point.

## Prerequisites

- [x] `GridConfig` exists with deep-merge and section-parse pattern
- [x] `NotificationPanelTheme.init(from:)` already implemented
- [x] `NotificationEventConfig` and `NotificationWatcherConfig` defined with defaults
- [x] `NotificationPanelManager.configure(theme:)` is ready
- [x] `NotificationEventHandler.stop()` and constructor exist
- [x] `NotificationFileWatcher.stop()` and `start()` exist
- [x] `GridConfig.onReload` callback field exists
- [x] Phase 4 complete: sources wired in main.swift (with empty defaults)

## Recommendation

BUILD

What needs to be built:
1. Add `parseNotifications(from:)` private method to `GridConfig` that extracts a `notifications:` YAML section and stores it as a new `private(set) var notifications: GridNotificationsConfig`
2. Add `GridNotificationsConfig` struct (runtime representation) and `GridNotificationsYAML` struct (Codable for YAML decode) to `GridConfig.swift`
3. Add a `NotificationStore.trim(to maxCount: Int)` method (called by parseNotifications via the store's add path)
4. Wire `gridConfig.onReload` in `main.swift` to call `configure(theme:)` on `NotificationPanelManager` and recreate the event handler and file watcher with updated configs
5. Change `let notificationEventHandler` and `let notificationFileWatcher` in main.swift to `var` so the `onReload` closure can replace them
