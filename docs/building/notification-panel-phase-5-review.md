# Review: Phase 5 - Configuration and polish

## Verdict: FAIL

---

## Spec Match

- [x] `NotificationsYAML` private struct defined with correct fields and CodingKeys
- [x] `EventRuleYAML` and `FileWatcherYAML` private structs defined
- [x] `GridNotificationsConfig` runtime struct defined and exposed as `private(set) var notifications`
- [x] `parseNotifications(from:)` called in `GridConfig.load()` alongside other parse* calls
- [x] `parseNotifications` method body matches pseudocode logic exactly
- [x] `trim(to maxCount:)` method implemented in `NotificationStore.swift`
- [x] `let` changed to `var` for `notificationEventHandler` and `notificationFileWatcher` in `main.swift`
- [x] `gridConfig.onReload` closure wired before `gridConfig.load()` call
- [x] Initial config application block runs after `load()` completes
- [x] Signal handlers reference the `var` bindings for cleanup
- [ ] `trim(to maxCount:)` is never called — `maxCount` config has no runtime effect

**Deviation — logging style:** `parseNotifications` uses `JSONLogger.shared.log(...)` rather than the `jlog(...)` convenience wrapper shown in the pseudocode. This is correct: `GridConfig` is a class outside a Task context where `jlog` is available. Not a defect.

**Deviation — `onReload` dispatch:** The pseudocode specified `DispatchQueue.main.async { }` wrapping the closure body. The implementation instead runs inside `Task { @MainActor in }`, making the `onReload` closure itself execute on `@MainActor`. This is functionally equivalent and cleaner. Not a defect.

**Missing callsite — `trim()`:** The pseudocode specifies `trim(to maxCount:)` should be "called after add() when a maxCount is configured." Neither `NotificationStore.add()`, nor the `onReload` closure, nor the initial config block in `main.swift` ever calls `trim()`. The method is implemented and compiles but has no callsite. The `maxCount` field is parsed and stored correctly in `GridNotificationsConfig`, but it has zero runtime effect.

---

## Dead Code

`NotificationStore.trim(to maxCount:)` — implemented at line 330, zero callsites. The method is not unreachable code (it is a valid actor method), but it is unused functionality. The associated `GridNotificationsConfig.maxCount` field is also populated correctly by `parseNotifications` but never consumed.

No other dead code found: no commented-out blocks, no debug statements, no unreachable code after early returns.

---

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All five "done when" criteria have corresponding implementation: YAML parsing (parseNotifications), theme hot-reload (onReload → configure(theme:)), event filter config (eventRules mapping), file/pipe path config (watcherPath), end-to-end wiring (onReload replaces handler + watcher). maxCount is parsed but not enforced — this criterion was listed as plan scope, not "done when". |
| Concurrency | PASS | `onReload` closure and initial config block both run inside `Task { @MainActor in }`. Inner `Task { await notificationEventHandler.stop() }` created from `@MainActor` context inherits actor isolation in Swift 5.9+, so `notificationEventHandler` mutation is actor-safe. `NotificationStore` is an actor; all calls use `await`. |
| Error Handling | PASS | `parseNotifications` catches all decode errors, logs them, and resets to defaults — correct for a non-fatal config parse. `gridConfig.load()` failure is caught and logged at line 211. `onReload` is only called after successful `load()` (line 726 in GridConfig). No silent failures. |
| Resource Mgmt | PASS | `notificationFileWatcher.stop()` called before reassignment in both `onReload` (line 166) and initial config block (line 201). `notificationEventHandler.stop()` awaited before reassignment. Signal handlers stop both components before shutdown. No leaked watchers. |
| Boundaries | PASS | `trim(to:)` guards `maxCount > 0`. `expandTilde` guards empty string. Theme construction guarded by `themeColors.isEmpty` check. Event handler replacement guarded by `!notifConfig.eventRules.isEmpty`. Watcher replacement guarded by `!notifConfig.watcherPath.isEmpty`. |
| Security | PASS | Config data feeds into color strings (theme), file paths (watcher), and notification titles (event rules). No shell execution from config values. Path expansion uses `NSString.expandingTildeInPath` (safe). No config values logged in ways that could leak sensitive data. |

---

## Defensive Programming

Checked against the key invariants:

| Item | Status | Evidence |
|------|--------|----------|
| No empty catch blocks | PASS | Both catch sites (parseNotifications line 960, load() line 211) log before resetting state |
| External input validated | PASS | YAML config decoded through typed Codable structs; invalid priority strings fall back to `.normal` via nil-coalescing |
| Error handling matches architectural pattern | PASS | Non-fatal config errors reset to defaults (consistent with `parseLayouts`, `parseAppRules` pattern throughout GridConfig) |
| No silent failures | PASS | Every error path logs with `JSONLogger.shared.log("err.grid.cfg.notifications", ...)` |
| Resource cleanup on error paths | PASS | `parseNotifications` error path assigns `GridNotificationsConfig()` (defaults), leaving no partial state |

---

## Issues (FAIL)

### 1. `trim(to maxCount:)` has no callsite — `max_count` config has no effect

- File: `grid-server/Sources/GridServer/Notifications/NotificationStore.swift:330`
- File: `grid-server/Sources/GridServer/main.swift:185-210` (initial config block)
- File: `grid-server/Sources/GridServer/main.swift:147-177` (onReload closure)

The pseudocode states `trim()` is "called after add() when a maxCount is configured." The method is fully implemented and correct, but nothing calls it. A user who sets `max_count: 200` in their config will see the value parsed and logged (`grid.cfg.notifications` event shows `max_count: 200`) but notifications will accumulate without bound.

Fix options (either is sufficient):

**Option A — call from `onReload` and initial config block in `main.swift`:** After replacing the event handler and watcher, add:

```swift
if notifConfig.maxCount > 0 {
    Task {
        await NotificationStore.shared.trim(to: notifConfig.maxCount)
    }
}
```

Add this in both the `onReload` closure and the initial config block.

**Option B — call from `NotificationStore.add()` when a max is configured:** This requires passing `maxCount` into the store (e.g., as a settable property), which is a larger change. Option A is the minimal fix consistent with the existing architecture.
