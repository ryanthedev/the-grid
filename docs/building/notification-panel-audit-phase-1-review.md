# Review: Phase 1 - HIGH-Severity Audit Fixes

## Verdict: PASS

## Spec Match

Plan requirements mapped to implementation:

- [x] **Finding #1 (CONC-3 ViewModel refresh race)** — `private var refreshTask: Task<Void, Never>?` declared at line 50 of `NotificationPanelViewModel.swift`. `refreshNotifications()` calls `refreshTask?.cancel()` before creating the new task, and the task body guards on `Task.isCancelled` before writing to `self.notifications`. Fully implemented.

- [x] **Finding #2 (LOGIC-11 RPC flag injection)** — `grid.notify.list`, `grid.notify.dismiss`, and `grid.notify.clear` all call `NotificationStore.shared` directly (lines 1958, 1994, 2003–2010 of `MessageHandler.swift`). None pass through `dispatchAndRespond`. Matches the "call store directly like `push` does" requirement.

- [x] **Finding #3 (CONC-2 FileWatcher isRunning race)** — `start()` in `NotificationFileWatcher.swift` wraps the `isRunning` check-and-set in `queue.sync` (lines 63–71), using a local `alreadyRunning` flag to exit after the sync block. The double-start TOCTOU is closed.

- [x] **Finding #4 (ERR-3 fstat unchecked)** — `openAndWatch()` now guards `fstat()` return value (lines 113–123), logs `err.notify.watcher.fstat` with path and errno, calls `tearDown()`, and schedules a retry via `queue.asyncAfter`. Fully implemented.

- [x] **Finding #5 (CONC-3 hot-reload TOCTOU)** — `main.swift` lines 158–166: old handler captured, then `Task { @MainActor in await oldHandler.stop(); notificationEventHandler = NotificationEventHandler(...) }`. Serialized on `@MainActor`; new handler is not created until old one has stopped. Duplicate concurrent registration prevented.

- [x] No unplanned additions found.

- [x] Test coverage: plan specifies "Backend only / existing 20 tests pass." No new unit tests were required for Phase 1 per the plan. Build confirmed passing by implementation agent.

## Dead Code

None found. No unused imports, unreachable code blocks, debug `print` statements, or commented-out code added by these fixes.

One pre-existing observation (not introduced by these fixes): `grid.notify.count` still uses `dispatchAndRespond` with `@notify count` command string — this is outside Phase 1 scope and not a new addition.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 5 findings mapped above; each done-when criterion met |
| Concurrency | PASS | See analysis below |
| Error Handling | PASS | See analysis below |
| Resource Mgmt | PASS | tearDown() called on fstat failure before retry; no fd leak |
| Boundaries | PASS | See analysis below |
| Security | PASS | list/dismiss/clear no longer accept arbitrary command strings |

### Concurrency — detailed

**Finding #1 (refreshTask cancellation):** The fix is correct. Because `NotificationPanelViewModel` is `@MainActor`, `refreshTask` is only ever accessed on the main actor — no separate lock is needed. Cancellation happens before the new task is launched in the same synchronous turn. The `guard !Task.isCancelled` inside the task body prevents stale results from landing after a faster subsequent refresh. No new race introduced.

**Finding #3 (isRunning queue.sync):** The pattern is correct. `queue.sync` provides mutual exclusion: exactly one caller sets `isRunning = true` and the other sees `alreadyRunning = true`. The subsequent `queue.async { self.openAndWatch() }` runs serially on the same queue, so `openAndWatch` always observes the committed `isRunning = true` state.

**Finding #5 (hot-reload serialization):** The `@MainActor`-isolated `Task` ensures `oldHandler.stop()` completes before the new `NotificationEventHandler` init (which self-registers in its own init Task). The file watcher replacement (lines 169–177) runs synchronously in the `onReload` closure on `@MainActor`, so the old watcher is stopped and the variable reassigned atomically before the new one starts. One nuance: the event handler replacement uses an inner `Task { @MainActor in ... }` rather than running inline. This means there is a brief window after `onReload` returns where the old handler has not yet been stopped and the new one has not yet been created. However, both run on `@MainActor` serially, so no duplicate concurrent processing occurs — the Task enqueues behind any currently executing work on the main actor. This is acceptable behavior.

### Error Handling — detailed

**Finding #4 (fstat guard):** On `fstat` failure the fix correctly: (1) logs with actionable data (path + errno), (2) calls `tearDown()` to close the already-opened fd (preventing fd leak), and (3) schedules a retry. The retry guard `if self.isRunning` correctly avoids a retry loop after `stop()` is called. No error is swallowed silently.

**Defensive programming check — silent failures:**
- No empty catch blocks introduced.
- No swallowed exceptions in the new code paths.
- `Task.isCancelled` is checked before mutating `@Published` state — not treating cancellation as silent success.
- The `dispatchAndRespond` path is no longer used for list/dismiss/clear, so no injection vector remains in those handlers.

### Boundaries — detailed

- `refreshNotifications()`: `min(selectedIndex, max(0, results.count - 1))` correctly handles empty results (clamps to 0). Pre-existing, unmodified by this fix.
- `fstat` retry: the `asyncAfter(deadline: .now() + 5)` guard checks `isRunning` to handle the case where `stop()` is called during the retry window. Correct.
- `grid.notify.dismiss`: validates `id` is non-empty before calling store. Pre-existing guard preserved.

## Defensive Programming

Checked against cc-defensive-programming crisis invariants:

| Check | Status |
|-------|--------|
| No executable code in assertions | PASS — no assertions added |
| No empty catch blocks | PASS — no catch blocks in new code |
| External input validated | PASS — list/dismiss/clear validate params before store calls |
| Assertions for bugs only | N/A — no assertions added |

No critical violations found.

## Issues

None. All 5 HIGH findings are closed by the implementation. No new issues introduced.
