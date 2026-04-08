# Discovery: iMessage Notifications Phase 3 - Conversation Detail Pop-Out Window

## Current State

### Notification Model (Notification.swift)
- `GridNotification` struct has: id, source, title, body, priority, timestamp, isRead, isPinned, isDismissed, action, ttl, warnBefore, groupCount, ttlResetDate
- **No `detailCmd` field** -- needs to be added
- `GridNotificationAction` enum supports: focusWindow, runShellCommand, openURL
- `NotificationLineDescriptor` (in NotificationFileWatcher.swift) is a private Codable struct for pipe JSON parsing -- also needs `detail_cmd` field

### NotificationPanelViewModel (NotificationPanelViewModel.swift)
- Handles vim-style key bindings in `handleKeyDown(keyCode:modifiers:)`
- Return key (keyCode 36) in normal mode calls `executeSelectedAction()` which returns `.executeAction(action)` if a notification has an action
- `NotificationPanelAction` enum: `.none`, `.executeAction(GridNotificationAction)`, `.enterFilterMode`, `.exitFilterMode`
- For phase 3, Return should check for `detailCmd` first before falling through to the existing action logic

### NotificationPanelWindow (NotificationPanelWindow.swift)
- NSWindow subclass, intercepts keyDown and dispatches to viewModel
- Handles `.executeAction` by calling `executeNotificationAction(_:)` which runs shell commands, opens URLs, etc.
- **New behavior needed:** a new action variant `.openDetail(detailCmd, title)` that the window routes to a DetailWindow manager

### NotificationFileWatcher (NotificationFileWatcher.swift)
- `NotificationLineDescriptor` is private, has fields: id, title, body, priority, action, ttl, warn_before
- `processLine(_:)` creates GridNotification from descriptor
- Needs to pass through `detail_cmd` from pipe JSON to the notification model

### iMessage Watcher Script (scripts/imessage-watch.py)
- `format_notification()` builds JSON with: id, title, body, ttl, warn_before
- **Does NOT set `detail_cmd`** -- needs to add it pointing to `imessage-watch.py --history <handle>`
- `--history` flag already implemented in `handle_history_flag()` / `fetch_history()`
- History output format: `[{"body": "...", "is_from_me": true/false, "timestamp": unix_ts}]`
- The plan says the detail window expects: `{"sender": "them"/"me", "text": "...", "date": "2m ago"}`
- The Swift side will parse the actual output format (`is_from_me`, `body`, `timestamp`) and compute relative times

### Theme (NotificationPanelTheme.swift)
- Dark background (#121212), cyan accent (#00BFFF), Berkeley Mono font
- Has all color tokens needed for the detail window (background, surface, textPrimary, textSecondary, accent, etc.)

### AppDelegate (AppDelegate.swift)
- Creates store, viewModel, window, fileWatcher
- No reference to detail windows -- will need to be managed separately (or by the panel window itself)

## What Needs to Be Built

### 1. Model Changes (Notification.swift)
- Add `detailCmd: String?` to `GridNotification`
- Add `detail_cmd: String?` to `NotificationLineDescriptor` (in NotificationFileWatcher.swift)

### 2. File Watcher Changes (NotificationFileWatcher.swift)
- Pass `detail_cmd` from descriptor to `GridNotification` init

### 3. Python Script Changes (imessage-watch.py)
- Add `detail_cmd` field to `format_notification()` output
- The script path needs to be resolvable -- use the script's own path via `__file__`

### 4. ViewModel Changes (NotificationPanelViewModel.swift)
- Add new `NotificationPanelAction` case: `.openDetail(command: String, title: String)`
- Modify `executeSelectedAction()` to check `detailCmd` first, return `.openDetail` if present
- Otherwise fall through to existing `.executeAction` behavior

### 5. New: DetailWindow.swift
- Singleton NSWindow manager -- only one detail window at a time
- Runs shell command asynchronously, parses JSON output
- Displays results in SwiftUI content view
- Escape or window close dismisses

### 6. New: DetailViews.swift
- SwiftUI views for the detail window content
- Message list showing sender direction (me/them) and relative timestamps
- Loading state while command is running
- Error state if command fails
- Matches existing theme (dark, Berkeley Mono, cyan accent)

### 7. Window Integration (NotificationPanelWindow.swift)
- Handle `.openDetail` action by delegating to DetailWindow manager

## Gaps & Risks

- The `--history` output format uses `is_from_me`/`body`/`timestamp` but the plan says `sender`/`text`/`date` -- the Swift parser will map between them
- Script path in `detail_cmd` needs to be absolute -- use `os.path.abspath(__file__)` in the Python script
- Only one detail window open at a time -- singleton pattern on a `@MainActor` class
- Detail window needs to run the shell command asynchronously and handle both success and failure
