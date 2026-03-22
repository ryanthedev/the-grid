# Review: Phase 2 - MEDIUM + LOW Audit Fixes

## Verdict: PASS

---

## Spec Match

Plan requirements (findings #6–#17) mapped to implementation:

- [x] **Finding #6 (CONC-2 MED): Store divergence documented** — `MessageHandler.swift` lines 1938–1941 contain a comment explicitly stating that `NotificationStore.shared` and the `notificationStore` injected into `GridCommandRouter` are the same singleton. Verified in `main.swift` line 303: `notificationStore: NotificationStore.shared`. Same object identity confirmed. Finding closed.

- [x] **Finding #7 (CONC-3 MED): exitVisualSelect moved inside async Task** — `NotificationPanelViewModel.swift` `bulkDismissVisualSelection()` (line 216) and `bulkPinVisualSelection()` (line 227) both call `exitVisualSelect()` then `refreshNotifications()` inside the `Task` body, after the `await store.*` calls complete. Mode change and refresh are sequenced atomically from the UI perspective. A comment on lines 220–222 and 233–235 documents the intent. Finding closed.

- [x] **Finding #8 (ERR-8 MED): runShellCommand do/catch with proper logging** — `NotificationPanelWindow.swift` lines 135–140: `try process.run()` is wrapped in `do/catch`. Success path logs `notify.action.exec`. Catch path logs `err.notify.action.exec` with command and error. No `try?` swallowing. Finding closed.

- [x] **Finding #9 (NULL-2 MED): NSScreen force-unwrap replaced with guard** — `NotificationPanelWindow.swift` lines 25–33: replaced force-unwrap with `if let screen = NSScreen.main ?? NSScreen.screens.first`. Fallback rect `NSRect(x: 0, y: 0, width: 400, height: 600)` used when no screen is available (headless/test). Finding closed.

- [x] **Finding #10 (NULL-6 MED): FileWatcher reads in loop until drain** — `NotificationFileWatcher.swift` `handleReadable()` lines 169–189: `while true` loop calls `read()` until `EAGAIN` (non-blocking fd drained), `EINTR` (signal, loop break is acceptable), a real error, or `bytesRead == 0` (EOF). All available data is consumed per dispatch source event. Finding closed.

- [x] **Finding #11 (LOGIC-11 MED): testPersistenceEmptyStore rewritten** — `NotificationStoreTests.swift` lines 448–476: test now adds a notification, dismisses it, and flushes before loading into `store2`. Verifies `activeCount == 0`, `allCount == 1`, and `fetched?.isDismissed == true`. Exercises the actual file round-trip rather than just testing the no-file-exists early return. Finding closed.

- [x] **Finding #12 (NULL-6 LOW): Empty exec:/url: payloads rejected** — `GridCommandRouter.swift` lines 988–994: `exec:` branch guards `!payload.trimmingCharacters(in: .whitespaces).isEmpty`; `url:` branch does the same. Comment documents intent. Finding closed.

- [x] **Finding #13 (ERR-8 LOW): Stale .tmp cleanup in catch** — `NotificationStore.swift` lines 136: `try? FileManager.default.removeItem(atPath: tmpPath)` inside the catch block. `tmpPath` is declared before the `do` block (line 113) so it is in scope in the catch. A comment on lines 134–136 explains the intent. Finding closed.

- [x] **Finding #14 (LOGIC-11 LOW): NotifyCount fallback output** — `NotifyCommand.swift` lines 207–211: `if let msg = result["message"] as? String { print(msg) } else { print("0") }`. Unexpected response format falls back to printing "0". A comment on lines 205–206 explains the scripting contract. Finding closed.

- [x] **Finding #15 (LOGIC-11 LOW): Unknown action types logged** — `NotificationFileWatcher.swift` `parseLineAction()` `default` case (line 302): logs `warn.notify.watcher.action` with `type` field. Finding closed.

- [x] **Finding #16 (CONC-2 LOW): isVisible set after makeKeyAndOrderFront** — `NotificationPanelManager.swift` lines 57–59: `NSApp.activate()` then `window?.makeKeyAndOrderFront(nil)` then `isVisible = true`. The flag is set after the window is ordered in, not before. Finding closed.

- [x] **Finding #17 (LOGIC-11 LOW): Bare = and _ keys documented** — `NotificationPanelViewModel.swift` lines 300–311: `case 24` (= key) comment reads "Bare = (without shift) is intentionally ignored: no binding defined for it." `case 27` (- key) comment reads "shift+- produces _ (underscore) which is intentionally ignored: no binding defined for it." Both no-ops are documented. Finding closed.

- [x] No unplanned additions found.

- [x] Test coverage: plan specifies "Backend only / existing tests pass + updated empty store test." `testPersistenceEmptyStore` now exercises the round-trip. No other new tests required per plan.

---

## Dead Code

None found. No unused imports, unreachable code, debug `print` statements, or commented-out code introduced by these fixes.

Pre-existing observation carried forward from Phase 1 review: `grid.notify.count` in `MessageHandler.swift` still uses `dispatchAndRespond` with `@notify count`. This routes through `GridCommandRouter.handleNotify` where `count` calls `notificationStore.count()` directly — no injection vector because count takes no user-supplied arguments. Not a new addition; not a finding.

---

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 12 findings mapped above; each done-when criterion met |
| Concurrency | PASS | See analysis below |
| Error Handling | PASS | See analysis below |
| Resource Mgmt | PASS | .tmp cleanup on failure; no new resource acquisitions |
| Boundaries | PASS | See analysis below |
| Security | PASS | Empty exec:/url: payloads rejected before use |

### Concurrency — detailed

**Finding #6 (store divergence):** The concern was that `MessageHandler` uses `NotificationStore.shared` while `GridCommandRouter` uses an injected `notificationStore`. Verified: `main.swift` line 303 passes `NotificationStore.shared` as the injected value. Both names point to the same actor instance. The comment in `MessageHandler.swift` makes this explicit. No divergence exists.

**Finding #7 (exitVisualSelect inside Task):** `bulkDismissVisualSelection` and `bulkPinVisualSelection` are `@MainActor` methods. The inner `Task` inherits the `@MainActor` context, so `exitVisualSelect()` (which mutates `@Published` state) is called on the main actor after the `await` store mutations complete. The sequence `dismiss/pin → exitVisualSelect → refreshNotifications` is correctly serialized. No race introduced.

**Finding #16 (isVisible ordering):** `isVisible = true` after `makeKeyAndOrderFront(nil)`. Since `NotificationPanelManager` is `@MainActor`, all access to `isVisible` is on the main thread. The ordering ensures external callers reading `isVisible` will not see `true` before the window has been ordered in. Correct.

### Error Handling — detailed

**Finding #8 (runShellCommand):** `Process.run()` can throw if the executable is not found or lacks execute permission. The `do/catch` correctly captures this; the error is logged with actionable data (command string, error description). The process runs fire-and-forget on a global queue — there is no further error propagation needed since this is a user-initiated action. No silent failures.

**Finding #13 (.tmp cleanup):** The `try?` for `removeItem` in the catch block is intentional: if the `.tmp` file was never written (e.g., `encoder.encode` failed), `removeItem` will fail with "file not found" — suppressing that error is correct. The store is re-marked dirty (`isDirty = true`) so the next mutation retries the write. The outer error is logged. No silent failure of the write itself.

**Finding #11 (persistence test):** The rewritten test actually calls `flush()` on a dirtied store, which exercises `persistNow()`. The previous version called `flush()` on a never-dirtied store, which returned early at `guard isDirty`. The new test confirms the full encode → write → atomic rename → load → decode path.

### Boundaries — detailed

**Finding #9 (NSScreen guard):** `NSScreen.main ?? NSScreen.screens.first` correctly handles: (1) main screen available — uses it; (2) no main screen but other screens exist — uses first; (3) no screens at all (headless/CI) — falls through to the safe default rect. The fallback rect `(0, 0, 400, 600)` is non-zero and non-negative, safe for `NSWindow` init.

**Finding #10 (read loop):** The drain loop correctly handles: (1) data available — accumulates into `lineBuffer`, calls `processLines()`; (2) `EAGAIN` — fd drained, breaks; (3) `EINTR` — signal interrupt, breaks (non-blocking fd will retry on next dispatch source fire); (4) other errno — logs error, breaks; (5) `bytesRead == 0` (EOF) — flushes remaining buffer, handles FIFO reconnect. All branches covered.

**Finding #12 (empty payload):** `.trimmingCharacters(in: .whitespaces).isEmpty` correctly rejects payloads that are empty or whitespace-only (e.g., `exec:   `). The `focus:` branch already requires `UInt32(payload)` to succeed, which fails on empty string. All three action types have appropriate boundary guards.

---

## Defensive Programming

Checked against cc-defensive-programming criteria:

| Check | Status |
|-------|--------|
| No empty catch blocks | PASS — all catch blocks log or re-mark dirty |
| No swallowed exceptions on failure paths | PASS — `try?` for `removeItem` is intentional no-op on missing file |
| External input validated before use | PASS — exec:/url: empty payloads rejected; store divergence documented |
| No broad exception types masking errors | PASS — no `catch Exception` or catch-all patterns introduced |
| Process execution failure logged | PASS — `runShellCommand` catch logs with command and error |

No critical violations found.

---

## Issues

None. All 12 MEDIUM and LOW findings are closed by the implementation. No new issues introduced.
