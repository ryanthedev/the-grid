# Review: Phase 5 - Configuration and polish (retry)

## Verdict: PASS

---

## Previous Failure

The first review (notification-panel-phase-5-review.md) failed because `trim(to maxCount:)` was implemented in `NotificationStore` but had zero callsites. The fix adds calls in both locations in `main.swift`:

1. `onReload` closure — after watcher replacement (lines 176-181)
2. Initial config application block — after watcher replacement (lines 219-224)

Both calls are guarded by `notifConfig.maxCount > 0` and dispatched via `Task { await NotificationStore.shared.trim(to: notifConfig.maxCount) }`.

---

## Spec Match

- [x] `NotificationsYAML` private struct with all fields and CodingKeys
- [x] `EventRuleYAML` and `FileWatcherYAML` private structs
- [x] `GridNotificationsConfig` runtime struct exposed as `private(set) var notifications`
- [x] `parseNotifications(from:)` called in `GridConfig.load()` alongside other parse* calls
- [x] `parseNotifications` body matches pseudocode logic exactly
- [x] `trim(to maxCount:)` implemented in `NotificationStore`
- [x] `trim(to maxCount:)` called in `onReload` closure when `maxCount > 0`
- [x] `trim(to maxCount:)` called in initial config block when `maxCount > 0`
- [x] `let` changed to `var` for `notificationEventHandler` and `notificationFileWatcher`
- [x] `gridConfig.onReload` closure wired before `gridConfig.load()` call
- [x] Initial config application block runs after `load()` completes
- [x] Signal handlers reference the `var` bindings for cleanup

**Test coverage:** Plan specifies "Backend only" with unit tests for store CRUD/persistence and manual testing for end-to-end. Phase 5 adds no new logic requiring unit tests (it is wiring, not algorithmic). Consistent with plan's test coverage level.

**Previously noted deviations (still present, still non-defects):**

- `parseNotifications` uses `JSONLogger.shared.log(...)` instead of `jlog(...)`. Correct: `GridConfig` is a `@MainActor` class; `jlog` is the appropriate wrapper in Task contexts. Not a defect.
- `onReload` runs directly on `@MainActor` rather than via `DispatchQueue.main.async`. Functionally equivalent and cleaner. Not a defect.

---

## Dead Code

None found. `trim(to:)` now has two callsites. No commented-out blocks, debug statements, or unreachable code found in any of the three modified files.

---

## Correctness Verification

### Requirements: PASS

All five Phase 5 "done when" criteria map to implementation:

| Criterion | Implementation |
|-----------|---------------|
| `notifications:` YAML section parsed and applied | `parseNotifications(from:)` at GridConfig.swift:912 |
| Theme colors configurable and hot-reloaded | `onReload` calls `NotificationPanelManager.shared.configure(theme:)` at main.swift:153-154 |
| Event filter list configurable | `eventRules` mapping in `parseNotifications`; handler replaced in `onReload` and initial block |
| File/pipe watch paths configurable | `watcherPath` parsed, watcher replaced in both `onReload` and initial block |
| End-to-end flow | All three sources wired: RPC (Phase 3), events (handler), file/pipe (watcher) |

`maxCount` enforcement is now present in both reload and startup paths.

### Concurrency: PASS

- `onReload` closure and initial config block run inside `Task { @MainActor in }`. Mutations to `notificationEventHandler` and `notificationFileWatcher` (both declared in the same `@MainActor` Task scope) are protected.
- Inner `Task { await notificationEventHandler.stop() }` created from `@MainActor` context — actor isolation inherited.
- `NotificationStore` is an actor; all calls use `await`. `trim(to:)` is an actor method called with `await`.
- No TOCTOU gaps: handler and watcher are replaced atomically within the `@MainActor` closure before the trim Task dispatches.

### Error Handling: PASS

- `parseNotifications` catches all decode errors, logs, and resets to defaults. No silent failures.
- `gridConfig.load()` failure caught and logged at main.swift:225.
- `onReload` is only called from `reload()` after a successful `load()` (GridConfig.swift:726).
- `trim(to:)` itself guards `maxCount > 0` before doing any work; actor errors propagate normally.

### Resource Management: PASS

- `notificationFileWatcher.stop()` called before reassignment in both `onReload` (main.swift:166) and initial config block (main.swift:208). No leaked watchers on reload.
- `notificationEventHandler.stop()` awaited before reassignment in both paths.
- Signal handlers (SIGINT/SIGTERM) stop both `notificationFileWatcher` and `notificationEventHandler` before shutdown. Since these are `var`, handlers use the current binding at execution time — correct.
- `NotificationStore.flush()` called in both signal handlers before exit.

### Boundaries: PASS

- `trim(to:)` guards `maxCount > 0` — safe on zero/unlimited config.
- `trim` call sites guarded by `notifConfig.maxCount > 0` — no spurious trim on default config.
- `expandTilde` guards empty string (GridConfig.swift:742).
- Theme construction guarded by `themeColors.isEmpty`.
- Event handler replacement guarded by `!notifConfig.eventRules.isEmpty`.
- Watcher replacement guarded by `!notifConfig.watcherPath.isEmpty`.
- `trim` correctly counts only unpinned IDs against `maxCount`, preserving all pinned notifications.

### Security: PASS

- Config values feed into color strings, file paths, and notification titles. No shell execution from config values.
- Path expansion uses `NSString.expandingTildeInPath` — safe against traversal for the tilde-expansion use case.
- No config values logged in ways that expose sensitive data.
- Priority string falls back to `.normal` on unrecognized values — no injection surface.

---

## Defensive Programming

| Item | Status | Evidence |
|------|--------|----------|
| No empty catch blocks | PASS | Both catch sites log before resetting state (GridConfig.swift:961, main.swift:225) |
| External input validated | PASS | YAML decoded through typed Codable structs; invalid priority strings handled by nil-coalescing to `.normal` |
| No silent failures | PASS | Every error path logs with `JSONLogger.shared.log("err.grid.cfg.notifications", ...)` |
| Resource cleanup on error paths | PASS | `parseNotifications` error path assigns `GridNotificationsConfig()`, leaving no partial state |
| Error handling matches architectural pattern | PASS | Non-fatal config errors reset to defaults, consistent with `parseLayouts`/`parseAppRules` pattern |
| `trim` called without `await` at outer scope risk | PASS | Trim dispatched via `Task { await ... }` from `@MainActor` context — actor requirement satisfied |
