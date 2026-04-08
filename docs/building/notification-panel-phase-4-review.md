# Review: Phase 4 - Notification sources (events, file/pipe watcher)

## Verdict: PASS

## Spec Match

- [x] `NotificationSourceConfig.swift` created with `EventNotificationRule`, `NotificationEventConfig`, `NotificationWatcherConfig` structs matching pseudocode exactly
- [x] `NotificationEventHandler.swift` implements `StateEventHandler`, registers with `EventRouter`, maps rules by `logInfo` event name, substitutes `{event}` token, calls `store.add()`, refreshes panel via `MainActor.run`
- [x] `NotificationFileWatcher.swift` implements all pseudocode sections: start/stop, `openAndWatch`, `handleReadable`, `handleFSEvent`, `processLines`, `processLine`, `parseLineAction`, `tearDown`
- [x] `NotificationLineDescriptor` private struct present in `NotificationFileWatcher.swift`
- [x] `main.swift` wires both sources after `NotificationStore.shared.load()`, passes both to signal handler cleanup for both SIGINT and SIGTERM
- [x] No unplanned additions
- [x] Test coverage: plan specifies "Backend only" with manual verification; no unit tests added for Phase 4 — matches plan

One minor deviation: the pseudocode shows `stop()` logging before the `queue.sync` block, but the implementation logs after. This is inconsequential and not a correctness issue.

## Dead Code

One empty closure present: the `setCancelHandler` in `openAndWatch` (line 114-116 of `NotificationFileWatcher.swift`) contains only a comment and no executable code. This is intentional — the comment explains the design decision (fd closed in `tearDown`, not the cancel handler, to avoid double-close). Not a defect.

No unused imports, unreachable code, or debug statements found.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All four Phase 4 "Done when" items implemented: event notifications configurable, file watcher reads lines, named pipe EOF handled with reopen, source labels distinguishable ("event", "pipe") |
| Concurrency | PASS | `NotificationFileWatcher` state (`fd`, `readSource`, `fsSource`, `lineBuffer`, `isRunning`) protected by serial `queue`; `stop()` uses `queue.sync` to block until teardown completes; `processLine` hops to `Task` for actor-isolated `store.add()`; `NotificationEventHandler` is a plain class registered with actor `EventRouter` — no shared mutable state of its own |
| Error Handling | PASS | `open()` failure retried after 5s with log; `read()` EAGAIN/EINTR silently ignored, other read errors logged; JSON parse failures logged and skipped (not silently swallowed); `fstat` return value ignored but failure leaves `isFIFO = false` which is a safe fallback (file path rather than pipe path) |
| Resource Mgmt | PASS | `tearDown()` cancels both DispatchSources and closes fd; called from `stop()`, from EOF/rotation reopen paths, and on shutdown via signal handler; `DispatchSource.cancel()` called before nil-assignment; no double-close risk because fd is only closed in `tearDown` not in cancel handlers |
| Boundaries | PASS | Empty `config.path` guard prevents start; `lineBuffer` correctly accumulates across reads; `processLines` uses `removeLast()` to preserve partial line; empty/whitespace-only lines skipped; invalid `priority` raw value falls back to `.normal`; unrecognized action `type` returns nil; missing `windowID`/`command`/`url` fields in action dict return nil |
| Security | PASS | Source is file/pipe paths from local config (not user-provided over network); `runShellCommand` action carries an arbitrary shell command string — this is an acknowledged design choice inherited from Phase 1's `GridNotificationAction` model, not a new surface introduced here |

## Defensive Programming

**Crisis invariants checked:**

- No empty catch blocks: the `catch` in `processLine` logs the error — PASS
- No executable code in assertions: no assertions used — N/A
- External input validated: JSON lines decoded via `Codable`; missing required `title` field causes a decode error (logged and skipped); optional fields have safe fallbacks — PASS
- Broad exception types: `catch` in `processLine` catches all `Error` — acceptable here since `JSONDecoder.decode` can throw various error types and the desired behavior (log + skip) is the same for all of them

**One finding (non-blocking):** `fstat()` return value is ignored at line 106 of `NotificationFileWatcher.swift`. If `fstat` fails (e.g., fd was closed between `open` and `fstat` — a race that cannot happen here since everything is on `self.queue`), `statBuf.st_mode` would be zero and `isFIFO` would be false, treating a pipe as a regular file. The queue serialization makes this race impossible in practice, but the unchecked return value is a minor hygiene issue.

**`isRunning` data race in `start()` (non-blocking):** `start()` reads and writes `isRunning` without dispatching to `self.queue` (lines 63-64), while `stop()` mutates it inside `queue.sync` and `openAndWatch()` reads it inside the queue. In normal usage (`start()` called once from main thread at startup, `stop()` called from signal handler) this is not a practical problem. However, it is a technically unsynchronized access. The pseudocode has the same structure, so this is a known design trade-off, not an implementation deviation.

## Issues

None that block PASS. The two findings above are hygiene observations:

1. `fstat` return value unchecked
   - File: `grid-server/Sources/GridServer/Notifications/NotificationFileWatcher.swift:106`
   - Impact: None in practice; queue serialization prevents the race that would make it matter
   - Fix (optional): `_ = fstat(fd, &statBuf)` with a guard or just leave as-is with a comment

2. `isRunning` read/write in `start()` not dispatched to queue
   - File: `grid-server/Sources/GridServer/Notifications/NotificationFileWatcher.swift:63-64`
   - Impact: None in practice given single-call startup pattern
   - Fix (optional): Wrap `start()` body in `queue.async` and remove the separate `queue.async` for `openAndWatch()`
