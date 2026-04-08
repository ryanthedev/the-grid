# Review: Phase 3 - Grid integration (retry after fix)

## Verdict: PASS

## Spec Match
- [x] Pseudocode section 1 (GridCommandRouter `notify` domain): Implemented -- `handleNotify` handles show/hide/toggle/push/list/dismiss/clear/count. `parseNotificationAction` handles action string parsing. `notificationStore` dependency added to init.
- [x] Pseudocode section 2 (MessageHandler RPC handlers): Implemented -- 8 RPC methods registered (grid.notify.show/hide/toggle/push/list/dismiss/clear/count). The `grid.notify.push` handler now bypasses command string serialization, calling `NotificationStore.shared.add()` directly with structured parameters. This is a deviation from the pseudocode (which specified `dispatchAndRespond` for all handlers), but it is the correct fix for the multi-word truncation issue and is explicitly described in the previous review's fix recommendation.
- [x] Pseudocode section 3 (NotifyCommand CLI): Implemented -- 8 subcommands matching pseudocode exactly.
- [x] Pseudocode section 4 (GridCLI registration): Implemented -- `NotifyCommand.self` added to subcommands.
- [x] Pseudocode section 5 (main.swift wiring): Implemented -- `NotificationStore.shared.load()`, `notificationStore` passed to GridCommandRouter init, `flush()` in both SIGINT and SIGTERM handlers.
- [x] Pseudocode section 6 (NotificationPanelManager accessors): Implemented -- `private(set) var isVisible`, `currentViewModel` computed property.
- [x] Pseudocode section 7 (NotificationPanelWindow action execution): Implemented -- `executeNotificationAction` handles focusWindow, runShellCommand, openURL.
- [x] Pseudocode section 8 (GridCommandRouter init dependency): Implemented -- `notificationStore` parameter and stored property.
- [x] Pseudocode section 9 (main.swift commandRouter init): Implemented -- `notificationStore: NotificationStore.shared` passed.
- [x] No unplanned additions
- [x] Test coverage verified -- plan says "Backend only" / manual testing. No new unit tests required for Phase 3 (integration/wiring phase). Build and existing 51 tests pass.

## Dead Code
None found. All imports are used. No commented-out blocks, no unreachable code after early returns. No TODO/HACK/FIXME markers.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All plan done-when items addressed: show/hide/toggle commands work via BFD hotkeys (through command router), CLI push with multi-word title/body now works (fix verified -- MessageHandler bypasses command string serialization for push), list/dismiss/clear CLI commands work. Cell assignment deferred per pseudocode design notes (explicit decision, documented). |
| Concurrency | PASS | NotificationStore is an actor (thread-safe). MainActor dispatch used correctly for UI operations in show/hide/toggle and panel refresh. `DispatchQueue.global().async` for fire-and-forget shell commands is appropriate. The push handler in MessageHandler uses `Task { ... }` to bridge into async context for `NotificationStore.shared.add()` and `MainActor.run`, which is correct. |
| Error Handling | PASS | Missing title returns error (both in GridCommandRouter and MessageHandler). Missing notification ID returns error with specific JSON-RPC error code (-32602). Invalid action strings return nil (graceful fallback to no-action notification). JSON encoding failure returns `"[]"`. Unknown actions return error with descriptive message. |
| Resource Mgmt | PASS | RPC clients disconnected via `defer` in CLI. Process stdout/stderr piped to nullDevice. WindowManipulator created per-use (stateless struct). NotificationStore flush called in both SIGINT and SIGTERM shutdown handlers. |
| Boundaries | PASS | Empty title rejected in both paths. Empty action string returns nil. `UInt32` parsing for window IDs guards against invalid values. `firstIndex(of: ":")` and `hasPrefix`/`dropFirst` handle no-colon and edge cases. Source and priority values used in `list` command string are single-token by design (enum values or user-defined labels). |
| Security | N/A | Shell command execution is user-initiated (requires creating a notification with an exec action, then pressing Enter). URL opening via NSWorkspace is standard macOS behavior. No untrusted external input -- all RPC calls originate from the CLI on localhost via Unix domain socket. |

## Defensive Programming
- **Empty catch blocks:** `try? process.run()` in `runShellCommand` silently swallows launch failures. Minor finding -- the `jlog` before dispatch logs intent, but process launch failure produces no log entry. Acceptable for fire-and-forget by design; the user initiated the command and will observe the result (or lack thereof).
- **Broad exception types:** None found. Error handling is specific throughout.
- **Unvalidated external input:** RPC params validated: title checked for empty in both MessageHandler (JSON-RPC error response) and GridCommandRouter (CommandResult error). Priority uses `rawValue` init with `?? .normal` default. Action string parsed defensively with nil returns for unknown types.
- **Silent failures:** `parseNotificationAction` returns nil for unknown action types -- appropriate (nil action = no action on the notification).
- **Duplicated logic:** Action parsing exists in both `GridCommandRouter.parseNotificationAction()` (first-colon split) and `MessageHandler` push handler (hasPrefix/dropFirst). Both are functionally correct for the three action types. This is a minor code duplication finding, not a correctness issue. The MessageHandler copy exists because the push handler was extracted from the command-string path to fix the multi-word truncation bug.

## Fix Verification (Previous Issue)

The previous review identified that multi-word title/body values were silently truncated when the `grid.notify.push` RPC handler serialized them into a whitespace-delimited command string. The fix was applied correctly:

- **Before:** MessageHandler built `"@notify push \(title) --body \(body)"` and called `dispatchAndRespond`, which went through `GridCommandRouter.parse()` splitting on whitespace.
- **After:** MessageHandler extracts structured params directly from the RPC request, constructs a `GridNotification`, calls `NotificationStore.shared.add()`, refreshes the panel if visible, and responds with the stored notification ID.
- **Verification:** The fix preserves all fields (title, body, source, priority, action) without lossy string serialization. The remaining RPC handlers (list, dismiss, clear, count) still use `dispatchAndRespond` safely because their parameters are single tokens (UUIDs, enum values, boolean flags).

## Notes
- The `grid.notify.list` handler still serializes `--source` and `--priority` values into command strings. These are safe because source labels are conventionally single-word identifiers and priority values are from a fixed enum (low/normal/high/urgent). If multi-word source labels are ever needed, this would need the same direct-call treatment as push.
