# Review: Phase 7 — Silent Errors, Crash Safety & Infrastructure

## Executed Results (Step 0)

| Command | Result |
|---------|--------|
| `swift build` | Build complete (1.88s) — no errors, 3 pre-existing baseline warnings only |
| `swift test` | **282 tests, 0 failures** (4.476s) |
| Lint/typecheck | Embedded in swift build — clean |

---

## Requirement Fulfillment

### DW-7.1
PREMISE:  "accepted sockets set `SO_NOSIGPIPE` + SIGPIPE removed from CrashReporter's fatal list (+ SIG_IGN); a mid-reply client disconnect yields EPIPE handled by `sock.err`, server stays up."
EVIDENCE:
- `CrashReporter.swift:55` — `fatalSignals` omits SIGPIPE (comment documents the intent).
- `CrashReporter.swift:85` — `signal(SIGPIPE, SIG_IGN)` installed process-wide in `CrashReporter.install()`.
- `SocketServer.swift:132-133` — `SocketServer.setNoSigPipe(clientSocket)` called after each `accept()`.
- `SocketServer.swift:245-248` — `setNoSigPipe` sets `SO_NOSIGPIPE` via `setsockopt`.
- `SocketServer.swift:276-288` — `sendMessage` handles `.disconnected` result (logs `sock.err`, does not crash).
TRACE:  Client disconnects mid-reply → `send()` returns -1/EPIPE → `FullWrite.writeAll` → `.disconnected` → `sendMessage` logs `sock.err` and returns → server continues.
TESTS: `test_DW_7_1_sigpipe_not_in_fatal_signal_list` (PASS), `test_DW_7_1_real_crash_signals_still_fatal` (PASS), `test_DW_7_1_write_to_closed_peer_returns_disconnected_not_signal` (PASS).
VERDICT: **PASS**

### DW-7.2
PREMISE:  "per-socket serialized writes + full-write loop — no interleaved/short JSONL frames."
EVIDENCE:
- `Phase7Policy.swift:40-76` — `FullWrite.writeAll` loops on partial writes, retries EINTR/EAGAIN, returns `.disconnected` on EPIPE/ECONNRESET/ENOTCONN/EBADF.
- `SocketServer.swift:16` — single `writeQueue` (serial) funnels all `send()` calls.
- `SocketServer.swift:270-289` — `sendMessage` calls `writeQueue.sync { FullWrite.writeAll(...) }`.
TRACE:  Two concurrent senders for socket fd → both serialized on `writeQueue` → first writes all bytes via loop before second starts → no frame interleaving.
TESTS: `test_DW_7_2_full_write_loop_handles_short_write` (PASS), `test_DW_7_2_full_write_retries_on_eintr_and_eagain` (PASS), `test_DW_7_2_full_write_reports_disconnected_on_epipe` (PASS), `test_DW_7_2_full_write_reports_disconnected_on_zero` (PASS), `test_DW_7_2_full_write_reports_failed_on_other_errno` (PASS), `test_DW_7_2_full_write_empty_is_ok` (PASS), `test_DW_7_2_full_frame_delivered_to_live_peer` (PASS).
VERDICT: **PASS**

### DW-7.3
PREMISE:  "all handlers registered before the socket accepts (or the dict guarded) — no startup 'method not found'."
EVIDENCE:
- `MessageHandler.swift:21-23` — `handlersQueue` serial queue guards `handlers` dict and `ready` flag.
- `MessageHandler.swift:43-51` — `finalizeRegistration()` sets `ready = true` under `handlersQueue`.
- `MessageHandler.swift:93-118` — `handle()` calls `lookup()` atomically; unregistered `grid.*` method with `!ready` returns -32000 (retryable), not -32601.
- `main.swift:239-249` — `registerGridHandlers` + `finalizeRegistration()` called synchronously before `NSApp.run()`.
TRACE:  Early `grid.focus` request before ready → `lookup` returns `(nil, ready:false)` → `stillStarting = true` → -32000 "Server initializing, retry" → client retries → after `finalizeRegistration` handler resolves.
TESTS: `test_DW_7_3_grid_method_before_ready_is_retryable_not_404` (PASS), `test_DW_7_3_unknown_method_after_ready_is_404` (PASS), `test_DW_7_3_registered_method_resolves` (PASS).
VERDICT: **PASS**

### DW-7.4
PREMISE:  "`GridState.load()` awaited before wiring (or load merges) — no clobber of early in-memory state."
EVIDENCE:
- `main.swift:165` — `await gridState.load()` is the first statement inside the wiring `Task`, before `gridReconciler.setup(...)`.
- `GridState.swift:113-139` — `load()` checks `hasAnySignificantState()`: if any space already has layout/cells, performs a merge rather than wholesale replacement.
TRACE:  Early `windowCreated` assigns window to space "5" → `load()` runs → `hasAnySignificantState()` is true → merge path: only keys not already held are loaded from disk → early assignment survives.
TESTS: `test_DW_7_4_load_does_not_clobber_significant_in_memory_state` (PASS), `test_DW_7_4_load_populates_when_memory_empty` (PASS).
VERDICT: **PASS**

### DW-7.5
PREMISE:  "`removeObserver` uses `await MainActor.run` (no actor-thread `main.sync`)."
EVIDENCE:
- `StateManager.swift:1315-1331` — `removeObserver(for:)` uses `await MainActor.run { observer.stopObserving() }`.
- `StateManager.swift:1319-1322` — Comment explicitly states "NOT DispatchQueue.main.sync — forward-progress violation".
- `StateManager.swift:2301-2305` — `rebuildAXObservers()` also uses `await MainActor.run` for stop calls.
TRACE:  `removeObserver(for: pid)` called on actor → `await MainActor.run { observer.stopObserving() }` suspends actor (releases thread back to cooperative pool) → main thread runs stopObserving → actor resumes.
TESTS: `test_DW_7_5_remove_observer_uses_main_actor_run` (PASS), `test_DW_7_5_statemanager_has_no_main_sync_call` (PASS — source-scan confirms no `DispatchQueue.main.sync` in production code).
VERDICT: **PASS**

### DW-7.6
PREMISE:  "observer registration reserves the dict slot synchronously; a replaced observer is stopped — no duplicate AXObservers."
EVIDENCE:
- `StateManager.swift:30-33` — `observerCreationInFlight: Set<pid_t>` guards the TOCTOU window.
- `StateManager.swift:1249-1255` — `createObserver` calls `ObserverSlotPolicy.canCreate(installed:inFlight:)` and immediately inserts into `observerCreationInFlight` synchronously (on actor) before spawning the `@MainActor Task`.
- `StateManager.swift:1297-1309` — `addApplicationObserver` stops any displaced observer via `await MainActor.run` before installing the new one.
- `Phase7Policy.swift:97-102` — `ObserverSlotPolicy.canCreate` rejects if `installed || inFlight`.
TRACE:  Two concurrent app-launch events for same pid → first call: `canCreate(false,false)=true`, inserts into `observerCreationInFlight` → second call: `canCreate(false,true)=false`, rejected → only one AXObserver installed.
TESTS: `test_DW_7_6_slot_reservation_rejects_inflight_and_installed` (PASS).
VERDICT: **PASS**

### DW-7.7
PREMISE:  "`AXUIElementSetMessagingTimeout` set on app elements."
EVIDENCE:
- `Phase7Policy.swift:17-21` — `makeAppElement(pid:)` calls `AXUIElementCreateApplication` then `AXUIElementSetMessagingTimeout(element, AXMessagingTimeoutPolicy.timeoutSeconds)` (0.5s).
- `StateManager.swift:353,583,2201` — `makeAppElement(pid:)` called at all three AX element creation sites (found via grep: lines 353, 583, 2201).
TRACE:  App window query → `makeAppElement(pid)` → AX element with 0.5s timeout → beachballing app returns `kAXErrorCannotComplete` in ≤0.5s instead of blocking for ~6s.
TESTS: `test_DW_7_7_messaging_timeout_policy_is_sane` (PASS), `test_DW_7_7_make_app_element_does_not_crash` (PASS).
VERDICT: **PASS**

### DW-7.8
PREMISE:  "MSS `resetAvailabilityCache()` on wake + re-probe on repeated `mss.fail`."
EVIDENCE:
- `StateManager.swift:2280` — `mssClient.resetAvailabilityCache()` called in `handleSystemWoke()`.
- `MSSClient.swift:99-147` — `isAvailable()` caches verdict in `cachedAvailable`; `resetAvailabilityCache()` sets it to `nil`.
- `MSSClient.swift:199-208` — `moveWindowToSpace` tracks `consecutiveMoveFailures`; calls `MSSReprobePolicy.shouldReprobe(consecutiveFailures:)` and on threshold (≥3) sets `cachedAvailable = nil` + calls `reconnect()`.
- `Phase7Policy.swift:109-115` — `MSSReprobePolicy.shouldReprobe` triggers at `failureThreshold = 3`.
TRACE:  3 consecutive move failures → `shouldReprobe(3)=true` → `cachedAvailable = nil`, `consecutiveMoveFailures = 0`, `reconnect()` → next `isAvailable()` re-handshakes Dock.
TESTS: `test_DW_7_8_reprobe_policy_on_repeated_fail` (PASS), `test_DW_7_8_isAvailable_caches_then_reset_reprobes` (PASS), `test_DW_7_8_reset_is_idempotent` (PASS).
VERDICT: **PASS**

### DW-7.9
PREMISE:  "BFD watcher re-arms on atomic-rename + logs open failure."
EVIDENCE:
- `BFDManager.swift:188-190` — `startConfigWatcher` logs `warn.bfd.watch` with errno on `open()` failure (guard fd >= 0 with jlog).
- `BFDManager.swift:202-215` — event handler checks `ConfigWatcherPolicy.shouldRearm(eventFlags:)`; on rename/delete, calls `stopConfigWatcher()` then re-opens after 50ms delay.
- `Phase7Policy.swift:121-125` — `ConfigWatcherPolicy.shouldRearm` returns true for `.rename` or `.delete`.
TRACE:  vim saves via atomic rename → `.rename` event fires → `shouldRearm` true → `stopConfigWatcher()` + `startConfigWatcher()` after 50ms → new fd on new inode → subsequent saves reload config.
TESTS: `test_DW_7_9_watcher_rearms_on_rename_or_delete` (PASS), `test_DW_7_9_watcher_does_not_rearm_on_plain_write` (PASS).
VERDICT: **PASS**

### DW-7.10
PREMISE:  "BFD reads both pipes concurrently with the wait — no >64KB-output deadlock."
EVIDENCE:
- `BFDExecutor.swift:53-69` — Two `DispatchQueue.global().async` tasks drain stdout/stderr via `readDataToEndOfFile()`; `process.waitUntilExit()` is called AFTER both readers are launched; `readGroup.wait()` called after `waitUntilExit()`.
- Comment at line 46-52 explicitly documents the deadlock fix.
TRACE:  Command emits >64KB to stdout → reader drains stdout pipe concurrently with process running → `waitUntilExit()` returns → `readGroup.wait()` joins both readers → no pipe-buffer deadlock.
TESTS: `test_DW_7_10_large_output_completes_without_deadlock` (PASS — 512KB stdout, completed in ~19ms), `test_DW_7_10_large_stderr_completes_without_deadlock` (PASS — 512KB stderr).
VERDICT: **PASS**

### DW-7.11
PREMISE:  "terminal `show()` treats AX-nil/setFrame-false as hard failure (no stranded off-screen window) + refuses a sentinel frame."
EVIDENCE:
- `GridTerminalManager.swift:236-243` — `show()` guards `getAXElement(pid:windowID:)` returning nil → logs error, returns `false` WITHOUT changing opacity/focus/`isHidden`.
- `GridTerminalManager.swift:240-243` — guards `setWindowFrame(element:frame:)` returning false → same abort path.
- `GridTerminalManager.swift:180-190` — `hide()` checks `TerminalFramePolicy.isOffScreenSentinel(frame)` before persisting; logs warning and skips if sentinel.
- `Phase7Policy.swift:131-138` — `TerminalFramePolicy.isOffScreenSentinel` triggers for x ≤ -5000 or y ≤ -5000.
- `GridTerminalManager.swift:133-136` — Toggle tier-1: on failed `show()` returns `.error("terminal show failed (AX)")`, not `.ok("shown")`.
TRACE:  AX element nil → `show()` returns false → caller returns `.error(...)` → `isHidden` stays true → no invisible focused window stranded off-screen.
TESTS: `test_DW_7_11_refuse_sentinel_frame` (PASS), `test_DW_7_11_accepts_real_frame` (PASS).
VERDICT: **PASS**

### DW-7.12
PREMISE:  "BFD blacklist/overrides match `bundleIdentifier`."
EVIDENCE:
- `BFDKeyHandler.swift:247-253` — Resolves `bundleID = frontApp?.bundleIdentifier` and `appName`; passes both to `AppMatchPolicy.isBlacklisted` and `AppMatchPolicy.resolveKey`.
- `Phase7Policy.swift:153-168` — `AppMatchPolicy.isBlacklisted` checks bundle id first, name as fallback. `resolveKey` prefers bundle id key.
TRACE:  Config has `"com.apple.finder"` in blacklist; Finder is frontmost → `bundleID = "com.apple.finder"` → `keys.contains("com.apple.finder") = true` → event passed through.
TESTS: `test_DW_7_12_bundle_id_match_predicate` (PASS), `test_DW_7_12_blacklist_matches_by_bundle_id` (PASS), `test_DW_7_12_resolve_key_prefers_bundle_id` (PASS).
VERDICT: **PASS**

### DW-7.13
PREMISE:  "`@notify` dispatches on `cmd.action` + forwards payload (show/hide/push/dismiss distinct, not all toggle)."
EVIDENCE:
- `GridCommandRouter.swift:1010-1011` — `action = cmd.action.isEmpty ? "toggle" : cmd.action`; `notificationName = NotifyActionPolicy.notificationName(forAction: action)`.
- `GridCommandRouter.swift:1013-1028` — `if NotifyActionPolicy.carriesPayload(action)`: builds `userInfo` from `cmd.flagValues` keyed by `forwardableParams`.
- `Phase7Policy.swift:176-227` — `NotifyActionPolicy.notificationName` maps: show→`.show`, hide→`.hide`, push→`.push`, dismiss→`.dismiss` (distinct, not collapse to toggle).
- `MessageHandler.swift:1512-1518` — `buildCommand` calls `NotifyActionPolicy.payloadFlags(lookup:purge:)` for notify domain, forwarding title/body/priority/source/id.
TRACE:  `@notify push --title "Done"` → `action="push"` → notificationName=`"com.thegrid.notify.push"` → `carriesPayload("push")=true` → userInfo=`["title":"Done"]` → `DistributedNotificationCenter.default().postNotificationName(.push, userInfo: ["title":"Done"])`.
TESTS: `test_DW_7_13_notify_action_to_notification_mapping` (PASS), `test_DW_7_13_buildcommand_forwards_notify_params` (PASS), `test_DW_7_13_payload_flags_omit_absent_params` (PASS), `test_DW_7_13_payload_actions_flagged` (PASS).
VERDICT: **PASS**

### DW-7.14
PREMISE:  "layout-cycle wipe deferred — a thrown apply no longer leaves the space wiped."
EVIDENCE:
- `GridState.swift:381-397` — `computeCycleLayout` / `computePreviousLayout` are pure: they compute and return the next layout ID without touching `cells`, `focusedCell`, `focusedWindow`, or `currentLayoutId`.
- `GridState.swift:363-374` — `setCurrentLayout` (which does wipe) is only called from `applyLayout`'s successful commit path, not from cycle computation.
TRACE:  `@layout cycle` → `computeCycleLayout` returns "B" (no mutation) → `applyLayout("B")` throws (e.g. layout not found) → `setCurrentLayout` never called → space.cells and currentLayoutId remain "A".
TESTS: `test_DW_7_14_compute_cycle_does_not_mutate_state` (PASS), `test_DW_7_14_compute_previous_wraps_without_mutation` (PASS), `test_DW_7_14_compute_empty_layouts_returns_current` (PASS), `test_DW_7_14_thrown_apply_preserves_prior_cells` (PASS).
VERDICT: **PASS**

**All requirements met: YES**

---

## Test-DW Coverage

| DW Item | Tests (ran in Step 0) |
|---------|----------------------|
| DW-7.1  | `Phase7PolicyTests.test_DW_7_1_*` (×2), `SocketWriteSafetyTests.test_DW_7_1_*` (×1) |
| DW-7.2  | `Phase7PolicyTests.test_DW_7_2_*` (×6), `SocketWriteSafetyTests.test_DW_7_2_*` (×1) |
| DW-7.3  | `StartupSafetyTests.test_DW_7_3_*` (×3) |
| DW-7.4  | `StartupSafetyTests.test_DW_7_4_*` (×2) |
| DW-7.5  | `ActorMainSyncTests.test_DW_7_5_*` (×2) |
| DW-7.6  | `Phase7PolicyTests.test_DW_7_6_*` (×1) |
| DW-7.7  | `Phase7PolicyTests.test_DW_7_7_*` (×2) |
| DW-7.8  | `Phase7PolicyTests.test_DW_7_8_*` (×1), `MSSReprobeTests.test_DW_7_8_*` (×2) |
| DW-7.9  | `Phase7PolicyTests.test_DW_7_9_*` (×2) |
| DW-7.10 | `BFDExecutorDeadlockTests.test_DW_7_10_*` (×2) |
| DW-7.11 | `Phase7PolicyTests.test_DW_7_11_*` (×2) |
| DW-7.12 | `Phase7PolicyTests.test_DW_7_12_*` (×3) |
| DW-7.13 | `Phase7PolicyTests.test_DW_7_13_*` (×4) |
| DW-7.14 | `LayoutCycleDeferralTests.test_DW_7_14_*` (×4) |

- [x] All DW items have corresponding automated tests that ran in Step 0.
- [x] Test coverage matches stated level (Backend 100% — every DW item has a test; pure predicates unit-tested off the OS boundary).

---

## Dead Code

None found in the reviewed files. Signal handler includes a `case SIGPIPE` branch in the formatter even though SIGPIPE is not in `fatalSignals` — this is intentional (belt-and-suspenders if somehow called with SIGPIPE) and documented in-code.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `writeQueue` (serial) serializes all `send()` calls; `socketQueue` (serial) serializes `clientSockets` mutation; `handlersQueue` (serial) guards `handlers` dict + `ready` flag. `observerCreationInFlight` reserved synchronously on actor before async MainActor task launch. No shared mutable state exposed without serialization. |
| Error Handling | PASS | All `send()` returns checked via `FullWrite.writeAll` → `WriteResult`; errors logged via `sock.err`. `CrashReporter.install()` logs on `open()` failure and continues. `BFDManager.startConfigWatcher` logs on `open()` failure. `GridTerminalManager.show()` returns `false` on AX/frame failures without side effects. |
| Resources | PASS | `BFDExecutor.execute()` sets a 30s timeout `DispatchWorkItem` and cancels it on completion. Socket `fd` closed in `handleClient`'s `defer`. Config watcher `fd` closed in `source.setCancelHandler { close(fd) }`. No resource leak paths identified. |
| Boundaries | PASS | `FullWrite.writeAll` handles `offset < total` loop correctly for any payload size. `TerminalFramePolicy.isOffScreenSentinel` uses threshold ≥5000 (not exact equality) for robustness. `SocketServer.socketPath` length is guarded before `strcpy`. |
| Security | PASS (see Security section below) | Notify payload forwarded as `userInfo` to `DistributedNotificationCenter` — not shell-executed. `buildCommand` assembles a string that goes through `CommandExecutor.submit()` and the router's `parseCommand` — no `Process`/shell invocation of notify params. Full security analysis in dedicated section. |

---

## Security Check

### Notify payload path (#22)

**Trust boundary:** Client sends JSON over UNIX socket (trusted local caller per UNIX socket permissions); the concern is whether notify params can inject shell commands or unbounded data.

**Analysis:**
- The `@notify push --title "Done"` path flows: RPC params → `buildCommand` → `dispatchAndRespond` → `CommandExecutor.submit` → `GridCommandRouter.dispatch` → `handleNotify`.
- Inside `handleNotify` (`GridCommandRouter.swift:963-1038`), params are passed to `DistributedNotificationCenter.default().postNotificationName(...)` as a typed `[String: String]` `userInfo` dictionary. They are NOT shell-executed.
- `NotifyActionPolicy.payloadFlags` wraps string values in double-quotes (`"\"\(val)\""`) — this quoting is for the command-string path, but `handleNotify` consumes `cmd.flagValues` directly, bypassing the quoted-string form. The router's `parseCommand` parses `--title "Done"` → `flagValues["title"] = "Done"` (quotes stripped by parser). So values arrive as plain strings, not shell-injected strings.
- The only `Process` invocation in `handleNotify` is `NSWorkspace.shared.openApplication(at: notifyAppURL, ...)` — a fixed URL path, not constructed from user data.
- Payload strings go into `NSDistributedNotification` `userInfo` (NSString typed dictionary). No `eval`, no `Process`, no `execve` with user data.

**Conclusion:** No injection vector. Payload is forwarded as structured data, not as a shell command.

### Socket write path (#46)

**Busy-spin analysis:** `FullWrite.writeAll` loops on `EINTR` and `EAGAIN`. On a UNIX domain socket `send()` does not return `EAGAIN` unless the socket is set to non-blocking (O_NONBLOCK). The accepted sockets in this code are NOT set non-blocking; they are blocking sockets. `EAGAIN` on a blocking socket is a spurious return that is safe to retry; on macOS UNIX domain sockets under normal load this essentially never fires. The loop terminates on: all bytes written (progress guaranteed each iteration since `sent > 0`), peer close, or non-retryable error. No infinite busy-spin is possible on a blocking socket under normal conditions.

**Serialization deadlock analysis:** `broadcast()` calls `socketQueue.sync { sendMessage(...) }` which calls `writeQueue.sync {}`. `socketQueue` and `writeQueue` are distinct serial queues with no mutual dependency; neither queue submits work to the other from within their own closure. No deadlock is possible.

---

## Notes (non-blocking)

1. **`FullWrite.writeAll` EAGAIN on a blocking socket** — Technically `EAGAIN` cannot occur on a blocking socket unless the send buffer is full and the socket would block, at which point `send()` blocks rather than returning `EAGAIN`. The retry is harmless but unreachable in practice. This is a minor correctness over-specification, not a bug.

2. **`broadcast()` lock ordering** — `broadcast` holds `socketQueue` while calling `sendMessage` which acquires `writeQueue`. This serializes broadcasts per-server, meaning a slow write to one client blocks broadcast to subsequent clients. Not a correctness defect (frames remain ordered per client), but a latency concern for future multi-client scenarios.

3. **`createObserver` retry task leaks if `StateManager` deallocated mid-retry** — The retry `Task { [weak self] in ... await self?.createObserver(...) }` guards with `[weak self]`, so deallocation is handled. Not a bug.

4. **`TerminalFramePolicy.sentinel` vs `threshold`** — The sentinel is `(-10000,-10000)` but the threshold for detection is `-5000`. Any frame with origin ≤ -5000 is treated as sentinel. This intentionally catches frames that land slightly off the exact sentinel due to display coordinate adjustments.

---

## Issues

None.

**VERDICT: PASS**
