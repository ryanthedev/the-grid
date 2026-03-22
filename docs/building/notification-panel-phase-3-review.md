# Review: Phase 3 - Grid integration

## Verdict: FAIL

## Spec Match
- [x] Pseudocode section 1 (GridCommandRouter `notify` domain): Implemented -- `handleNotify` handles show/hide/toggle/push/list/dismiss/clear/count. `parseNotificationAction` handles action string parsing. `notificationStore` dependency added to init.
- [x] Pseudocode section 2 (MessageHandler RPC handlers): Implemented -- 8 RPC methods registered (grid.notify.show/hide/toggle/push/list/dismiss/clear/count).
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
None found. All imports are used. No commented-out blocks or unreachable code after early returns.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | FAIL | Multi-word title/body values broken through RPC command string path (see Issue 1) |
| Concurrency | PASS | NotificationStore is an actor (thread-safe). MainActor dispatch used correctly for UI operations. `DispatchQueue.global().async` for fire-and-forget shell commands is appropriate. |
| Error Handling | PASS | Missing title returns error. Missing notification ID returns error. Invalid action strings return nil (graceful fallback). JSON encoding failure returns `"[]"`. Unknown actions return error. |
| Resource Mgmt | PASS | RPC clients disconnected via `defer`. Process stdout/stderr piped to nullDevice. WindowManipulator created per-use (no leaked connections). |
| Boundaries | PASS | Empty title rejected. Empty action string returns nil. `UInt32` parsing for window IDs guards against invalid values. `firstIndex(of: ":")` handles no-colon case. |
| Security | N/A | Shell command execution is user-initiated (requires creating a notification with an exec action, then pressing Enter on it). This is intentional design -- the user controls both the command and the trigger. No untrusted external input. |

## Defensive Programming
- **Empty catch blocks:** `try? process.run()` in `runShellCommand` silently swallows launch failures. Minor -- the `jlog` before dispatch logs intent. However, process launch failure produces no log entry. Not critical since this is fire-and-forget by design.
- **Broad exception types:** None found. Error handling is specific.
- **Unvalidated external input:** RPC params validated (title checked for empty, id checked for presence). Priority uses `rawValue` init with `?? .normal` default. Action string parsed defensively with nil returns.
- **Silent failures:** `parseNotificationAction` returns nil for unknown action types -- this is appropriate (nil action = no action on the notification).

## Issues (if FAIL)

### 1. Multi-word title and body values are silently truncated via RPC path (CRITICAL)
- **File:** `/Users/r/repos/theGrid/.claude/worktrees/notification-panel/grid-server/Sources/GridServer/MessageHandler.swift:1904-1906`
- **Problem:** The MessageHandler builds a command string by interpolating raw values: `"@notify push \(title)"` and `"--body \(body)"`. The `GridCommandRouter.parse()` method splits on whitespace. If title is `"Hello World"`, it becomes two tokens. The parser takes `args[0] = "Hello"` as the title and `"World"` becomes a stray argument. Same issue for `--body`, `--source`, and `--action` (though action values like `"exec:echo hello world"` also break).
- **Impact:** The plan's done-when item says `thegrid notify push "title" --body "text"` works via CLI. The CLI correctly receives quoted multi-word strings from the shell (ArgumentParser), but then passes them via RPC to MessageHandler, which re-serializes them into a command string that breaks on spaces. Any notification with a multi-word title or body will have its content silently truncated.
- **Fix:** Either (a) quote the interpolated values in the command string and update the parser to handle quoted tokens, or (b) bypass the command string serialization for `grid.notify.push` by having the RPC handler call `commandRouter.handleNotify()` directly with structured parameters instead of serializing to a string and re-parsing. Option (b) is cleaner -- it avoids the lossy string round-trip entirely. Alternatively, the existing parser could be extended to support quoted strings (matching how BFD hotkey commands handle this).
