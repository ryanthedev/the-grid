# Discovery: GridNotify Standalone App (Phase 1)

## What Exists

### Notification Code in grid-server (to adapt)

All source lives in `grid-server/Sources/GridServer/Notifications/`:

| File | Lines | Role | Reusable? |
|------|-------|------|-----------|
| `Notification.swift` | 157 | Data model (GridNotification, GridNotificationPriority, GridNotificationAction, GridNotificationFilter, GridNotificationStoreData) | YES - copy verbatim |
| `NotificationStore.swift` | 358 | Actor-based CRUD store with debounced persistence, load/save to notifications.json | YES - adapt (remove jlog references to grid-server's JSONLogger; use local copy) |
| `NotificationFileWatcher.swift` | 321 | DispatchSource-based pipe/file reader, parses JSON lines, feeds store | YES - adapt (remove NotificationPanelManager.shared references) |
| `NotificationPanelViewModel.swift` | 401 | @MainActor ObservableObject bridging store to SwiftUI, vim key handling | YES - adapt (decouple from grid-server singletons) |
| `NotificationPanelViews.swift` | 331 | SwiftUI views (content, header, filter bar, list, item, empty, status bar) | YES - copy verbatim |
| `NotificationPanelWindow.swift` | 162 | NSWindow subclass with keyDown interception | YES - adapt (remove grid-server action execution dependencies) |
| `NotificationPanelTheme.swift` | 133 | Theme struct with hex parsing and defaults | YES - copy verbatim |
| `NotificationSourceConfig.swift` | 57 | Config structs (EventNotificationRule, NotificationEventConfig, NotificationWatcherConfig) | PARTIAL - only need NotificationWatcherConfig |
| `NotificationPanelManager.swift` | 105 | Singleton orchestrating show/hide, activation policy toggle, trackSelf/untrackSelf | NO - replaced by AppDelegate |
| `NotificationEventHandler.swift` | 60 | Maps grid StateEvents to notifications via EventRouter | NO - not needed in standalone app |

### Utility Code to Duplicate

| File | Lines | What to duplicate |
|------|-------|-------------------|
| `JSONLogger.swift` | 229 | JSONLogWriter + JSONLoggerImpl + Span + CurrentSpan + jlog(). Change log file path to `thegrid-notify.json` |
| `XDG.swift` | 94 | XDG enum (configHome, stateHome, configDirs, findConfigFiles). Remove JSONLogger.shared references (standalone has its own) |

### SPM Package Pattern (from grid-server/Package.swift)

- swift-tools-version: 5.9
- macOS(.v13)
- Dependencies: Yams (from: "5.0.0") -- needed for YAML config
- Executable target pattern: `.executableTarget(name:, dependencies:, path:)`

### Build Pattern (from Makefile)

- Version.swift generated at build time with `GridServerVersion` and `GridServerCommit`
- Info.plist with VERSION_PLACEHOLDER replaced at bundle time
- Entitlements: minimal (`com.apple.security.app-sandbox: false`)
- Code signing: `thegrid-dev` identity

### Config Format (from GridConfig.swift)

Current grid-server notifications config is nested under `notifications:` in config.yaml:
```yaml
notifications:
  theme:
    background: "#121212"
  file_watcher:
    path: "~/.local/state/thegrid/notify.pipe"
    source_label: "pipe"
  max_count: 200
```

For GridNotify standalone, this becomes the top-level of `notify.yaml`.

## What's New (to create)

### Package Structure
```
grid-notify/
  Package.swift
  Sources/GridNotify/
    main.swift              -- NSApp lifecycle, AppDelegate
    AppDelegate.swift       -- Window management, show/hide, activation policy
    Notification.swift      -- Data model (copied)
    NotificationStore.swift -- Persistence actor (adapted)
    NotificationFileWatcher.swift -- Pipe/file reader (adapted)
    NotificationPanelViewModel.swift -- ViewModel (adapted)
    NotificationPanelViews.swift  -- SwiftUI views (copied)
    NotificationPanelWindow.swift -- NSWindow subclass (adapted)
    NotificationPanelTheme.swift  -- Theme (copied)
    NotifyConfig.swift      -- YAML config loading for notify.yaml
    JSONLogger.swift        -- JSONL logging (adapted from grid-server)
    XDG.swift               -- XDG paths (adapted)
    CurrentSpan.swift       -- TaskLocal span context (copied)
  Info.plist
  grid-notify.entitlements
```

### Key Differences from grid-server

1. **No EventRouter/EventHandler** -- standalone app, no grid events
2. **No StateManager/WindowManipulator** -- no window management
3. **No PickerManager** -- no picker
4. **Own NSApp lifecycle** -- AppDelegate with `.regular` activation policy
5. **Own config file** -- `~/.config/thegrid/notify.yaml` (not nested in config.yaml)
6. **Own log file** -- `~/.local/state/thegrid/thegrid-notify.json`
7. **Simpler action execution** -- only runShellCommand and openURL (no focusWindow without grid-server)

### Dependencies

- `Yams` (5.0.0+) -- YAML config parsing
- No other external dependencies (no ArgumentParser, no swift-log, no OpenTelemetry, no mss)

## Gaps / Risks

1. **focusWindow action**: The existing NotificationPanelWindow.executeNotificationAction uses StateManager and WindowManipulator (grid-server only). In standalone, focusWindow action cannot work. Will keep the enum case but log a warning and no-op.

2. **NotificationPanelManager.shared references in FileWatcher**: The processLine method calls `NotificationPanelManager.shared.currentViewModel?.refreshNotifications()`. This must be replaced with a callback/delegate pattern.

3. **jlog function**: Uses CurrentSpan TaskLocal from grid-server. Need to duplicate CurrentSpan.swift and the jlog convenience function.

4. **Version.swift**: grid-server generates this from Makefile. GridNotify needs the same pattern. For Phase 1, hardcode a placeholder; Phase 2 adds Makefile integration.

5. **No tests for existing notification code**: grid-server has no notification tests. Plan says 3-5 tests for NotificationStore CRUD and persistence.
