# Review: Phase 7 - Concurrency Correctness Fixes (Sample 3)

## Executed Results (Step 0)

- Build: `swift build` → Build complete! (0.47s), exit 0
- Test suite: `swift test` → 282 tests, 0 failures, exit 0
- Typecheck: included in `swift build` — clean
- Lint: no separate linter; Swift compiler warnings are the baseline (pre-existing baseline warnings confirmed not new)

All 282 tests passed. No baseline warnings introduced by this phase.

---

## Requirement Fulfillment

### DW-7.1
PREMISE:  "accepted sockets set SO_NOSIGPIPE + SIGPIPE removed from CrashReporter's fatal list (+ SIG_IGN); a mid-reply client disconnect yields EPIPE handled by sock.err, server stays up."
EVIDENCE: CrashReporter.swift:55 (`fatalSignals` excludes SIGPIPE), CrashReporter.swift:85 (`signal(SIGPIPE, SIG_IGN)`), SocketServer.swift:132 (`SocketServer.setNoSigPipe(clientSocket)`), SocketServer.swift:245-248 (`setNoSigPipe` sets `SO_NOSIGPIPE`), SocketServer.swift:275-289 (EPIPE handled as `.disconnected`, logs `sock.err`, does not crash)
TRACE:    peer closes mid-reply → `send()` returns -1/EPIPE → `FullWrite.writeAll` returns `.disconnected` → `sendMessage` logs `sock.err` and returns → server continues accepting
VERDICT:  PASS — `test_DW_7_1_sigpipe_not_in_fatal_signal_list`, `test_DW_7_1_real_crash_signals_still_fatal`, `test_DW_7_1_write_to_closed_peer_returns_disconnected_not_signal` all pass

### DW-7.2
PREMISE:  "per-socket serialized writes + full-write loop — no interleaved/short JSONL frames."
EVIDENCE: SocketServer.swift:16 (`writeQueue` serial queue), SocketServer.swift:270 (`writeQueue.sync { FullWrite.writeAll(...) }`), Phase7Policy.swift:44-76 (`FullWrite.writeAll` loops on partial writes and retryable errors)
TRACE:    `sendMessage` encodes to `[UInt8]`, dispatches `writeQueue.sync` (serializes concurrent writers), then `FullWrite.writeAll` loops until all bytes sent, retrying on EINTR/EAGAIN
VERDICT:  PASS — `test_DW_7_2_full_write_loop_handles_short_write`, `test_DW_7_2_full_write_retries_on_eintr_and_eagain`, `test_DW_7_2_full_write_reports_disconnected_on_epipe`, `test_DW_7_2_full_frame_delivered_to_live_peer` all pass

### DW-7.3
PREMISE:  "all handlers registered before the socket accepts (or the dict guarded) — no startup 'method not found'."
EVIDENCE: MessageHandler.swift:21 (`handlersQueue` serial queue guards `handlers` dict and `ready` flag), MessageHandler.swift:44-51 (`finalizeRegistration()` sets `ready = true`), MessageHandler.swift:93-119 (lookup returns `(handler, ready)`; if `!ready && method.hasPrefix("grid.")` returns -32000 retryable instead of -32601), main.swift:239-249 (`registerGridHandlers` then `finalizeRegistration()` before socket is accepting requests)
TRACE:    early `grid.focus` request → `lookup()` returns `(nil, false)` → error code -32000 "Server initializing, retry" → client retries → after `finalizeRegistration()` → `(handler, true)` → executes
VERDICT:  PASS — `test_DW_7_3_grid_method_before_ready_is_retryable_not_404`, `test_DW_7_3_unknown_method_after_ready_is_404`, `test_DW_7_3_registered_method_resolves` all pass

### DW-7.4
PREMISE:  "GridState.load() awaited before wiring (or load merges) — no clobber of early in-memory state."
EVIDENCE: main.swift:165 (`await gridState.load()` before `gridReconciler.setup(...)`), GridState.swift:113-139 (`load()` calls `hasAnySignificantState()` and merges: only imports persisted spaces whose in-memory counterpart is empty)
TRACE:    early `assignWindow` to space "5" cell "0" (before load) → `hasAnySignificantState()` returns true → `load()` skips overwriting space "5" → assignment ["0": [42]] survives
VERDICT:  PASS — `test_DW_7_4_load_does_not_clobber_significant_in_memory_state`, `test_DW_7_4_load_populates_when_memory_empty` pass

### DW-7.5
PREMISE:  "removeObserver uses await MainActor.run (no actor-thread main.sync)."
EVIDENCE: StateManager.swift:1315-1331 (`removeObserver` calls `await MainActor.run { observer.stopObserving() }`, comment explicitly names the anti-pattern), ActorMainSyncTests source-scan confirms no `DispatchQueue.main.sync` exists in StateManager.swift after stripping line comments
TRACE:    app terminates → `removeObserver(for: pid)` → actor suspends at `await MainActor.run` → main actor runs `stopObserving()` → actor resumes, removes dict entry
VERDICT:  PASS — `test_DW_7_5_statemanager_has_no_main_sync_call`, `test_DW_7_5_remove_observer_uses_main_actor_run` pass

### DW-7.6
PREMISE:  "observer registration reserves the dict slot synchronously; a replaced observer is stopped — no duplicate AXObservers."
EVIDENCE: StateManager.swift:1249-1255 (`ObserverSlotPolicy.canCreate` rejects if installed or inFlight; `observerCreationInFlight.insert(pid)` before spawning MainActor Task), StateManager.swift:1297-1310 (`addApplicationObserver` stops displaced observer via `await MainActor.run { displaced.stopObserving() }` before overwriting slot), Phase7Policy.swift:98-102 (`ObserverSlotPolicy.canCreate` predicate)
TRACE:    second `createObserver(pid:)` call while first is in-flight → `observerCreationInFlight.contains(pid)` is true → `canCreate` returns false → returns without spawning duplicate
VERDICT:  PASS — `test_DW_7_6_slot_reservation_rejects_inflight_and_installed` passes

### DW-7.7
PREMISE:  "AXUIElementSetMessagingTimeout set on app elements."
EVIDENCE: Phase7Policy.swift:17-21 (`makeAppElement(pid:)` calls `AXUIElementCreateApplication` then `AXUIElementSetMessagingTimeout(element, AXMessagingTimeoutPolicy.timeoutSeconds)`), StateManager.swift:1257 (`let observer = ApplicationObserver(pid: pid, appName: appName)` — ApplicationObserver uses `makeAppElement`)
TRACE:    `createObserver(pid:)` → creates `ApplicationObserver` → `ApplicationObserver` calls `makeAppElement(pid:)` → AX element gets 0.5s timeout before any IPC
VERDICT:  PASS — `test_DW_7_7_messaging_timeout_policy_is_sane`, `test_DW_7_7_make_app_element_does_not_crash` pass

### DW-7.8
PREMISE:  "MSS resetAvailabilityCache() on wake + re-probe on repeated mss.fail."
EVIDENCE: StateManager.swift:2280 (`mssClient.resetAvailabilityCache()` in wake handler), MSSClient.swift:203-208 (`MSSReprobePolicy.shouldReprobe` triggers cache invalidation + reconnect after 3 consecutive `moveWindowToSpace` failures), MSSClient.swift:150-154 (`resetAvailabilityCache` sets `cachedAvailable = nil`)
TRACE:    wake event → StateManager's wake handler → `mssClient.resetAvailabilityCache()` sets `cachedAvailable = nil` → next `isAvailable()` re-handshakes. Separately: 3 consecutive move failures → `shouldReprobe` → `cachedAvailable = nil` + `reconnect()`
VERDICT:  PASS — `test_DW_7_8_reprobe_policy_on_repeated_fail`, `test_DW_7_8_isAvailable_caches_then_reset_reprobes`, `test_DW_7_8_reset_is_idempotent` pass

### DW-7.9
PREMISE:  "BFD watcher re-arms on atomic-rename + logs open failure."
EVIDENCE: BFDManager.swift:186-192 (open failure logs `warn.bfd.watch` with errno + path), BFDManager.swift:201-216 (`source.setEventHandler` calls `ConfigWatcherPolicy.shouldRearm(eventFlags: flags)`; on rename/delete: `stopConfigWatcher()` then deferred `startConfigWatcher()`), Phase7Policy.swift:121-125 (`ConfigWatcherPolicy.shouldRearm` returns true for `.rename` or `.delete`)
TRACE:    vim saves via atomic rename → DispatchSource fires `.rename` event → `shouldRearm` returns true → `stopConfigWatcher()` + `startConfigWatcher()` after 50ms → new fd on new inode
VERDICT:  PASS — `test_DW_7_9_watcher_rearms_on_rename_or_delete`, `test_DW_7_9_watcher_does_not_rearm_on_plain_write` pass

### DW-7.10
PREMISE:  "BFD reads both pipes concurrently with the wait — no >64KB-output deadlock."
EVIDENCE: BFDExecutor.swift:54-69 (two `DispatchQueue.global().async` blocks drain stdout and stderr into `stdoutData`/`stderrData`, using a `DispatchGroup`; `process.waitUntilExit()` called after both reads are started; `readGroup.wait()` after `waitUntilExit`)
TRACE:    command emits 512KB stdout → reader goroutine drains pipe continuously → `waitUntilExit` returns without blocking on full buffer → `readGroup.wait()` joins readers → returns
VERDICT:  PASS — `test_DW_7_10_large_output_completes_without_deadlock`, `test_DW_7_10_large_stderr_completes_without_deadlock` pass (10s timeout, actual <<1s)

### DW-7.11
PREMISE:  "terminal show() treats AX-nil/setFrame-false as hard failure (no stranded off-screen window) + refuses a sentinel frame."
EVIDENCE: GridTerminalManager.swift:236-243 (`show()`: guard on `getAXElement` nil → returns false without touching opacity/focus/isHidden; guard on `setWindowFrame` false → same abort), GridTerminalManager.swift:186-191 (`hide()`: `TerminalFramePolicy.isOffScreenSentinel` check refuses to save sentinel frame; logs `warn.term.frame`), Phase7Policy.swift:131-139 (`TerminalFramePolicy.isOffScreenSentinel`)
TRACE:    AX element nil → `show()` returns false → `toggle()` returns `.error("terminal show failed (AX)")` → window not stranded (opacity/isHidden unchanged)
VERDICT:  PASS — `test_DW_7_11_refuse_sentinel_frame`, `test_DW_7_11_accepts_real_frame` pass

### DW-7.12
PREMISE:  "BFD blacklist/overrides match bundleIdentifier."
EVIDENCE: BFDKeyHandler.swift:248-262 (resolves `bundleID = frontApp?.bundleIdentifier`, passes to `AppMatchPolicy.isBlacklisted` and `AppMatchPolicy.resolveKey`), Phase7Policy.swift:148-167 (`AppMatchPolicy` checks bundleID first, falls back to name)
TRACE:    frontmost app has bundleIdentifier "com.apple.finder" → `isBlacklisted(blacklist, bundleID: "com.apple.finder", name: "Finder")` returns true → event passed through
VERDICT:  PASS — `test_DW_7_12_bundle_id_match_predicate`, `test_DW_7_12_blacklist_matches_by_bundle_id`, `test_DW_7_12_resolve_key_prefers_bundle_id` pass

### DW-7.13
PREMISE:  "@notify dispatches on cmd.action + forwards payload (show/hide/push/dismiss distinct, not all toggle)."
EVIDENCE: Phase7Policy.swift:175-194 (`NotifyActionPolicy.notificationName` maps each action to a distinct name), Phase7Policy.swift:214-227 (`payloadFlags` builds `--title "val"` etc. from params), MessageHandler.swift:1512-1518 (`buildCommand` for domain "notify" calls `NotifyActionPolicy.payloadFlags`)
TRACE:    `grid.notify.push` with `{title:"T", body:"B"}` → `buildCommand("notify", "push", params)` → `@notify push --title "T" --body "B"` → `executor.submit` → `dispatch` → router sends `com.thegrid.notify.push` notification with payload
VERDICT:  PASS — `test_DW_7_13_notify_action_to_notification_mapping`, `test_DW_7_13_buildcommand_forwards_notify_params`, `test_DW_7_13_payload_flags_omit_absent_params`, `test_DW_7_13_payload_actions_flagged` pass

### DW-7.14
PREMISE:  "layout-cycle wipe deferred — a thrown apply no longer leaves the space wiped."
EVIDENCE: GridState.swift:381-397 (`computeCycleLayout`/`computePreviousLayout` are pure reads, no mutation), GridState.swift:363-373 (`setCurrentLayout` — the wipe — is called only from `applyLayout` body), LayoutCycleDeferralTests.swift: thrown apply leaves layout "A" + cells intact
TRACE:    `@layout cycle` → `computeCycleLayout` returns "B" (no mutation) → `applyLayout("B")` throws → `setCurrentLayout` never called → space retains layout "A" + cells
VERDICT:  PASS — `test_DW_7_14_compute_cycle_does_not_mutate_state`, `test_DW_7_14_thrown_apply_preserves_prior_cells`, `test_DW_7_14_compute_previous_wraps_without_mutation`, `test_DW_7_14_compute_empty_layouts_returns_current` pass

**All requirements met: YES**

---

## Test-DW Coverage

| DW Item | Test(s) | Location |
|---------|---------|----------|
| DW-7.1 | test_DW_7_1_sigpipe_not_in_fatal_signal_list, test_DW_7_1_real_crash_signals_still_fatal, test_DW_7_1_write_to_closed_peer_returns_disconnected_not_signal | Phase7PolicyTests, SocketWriteSafetyTests |
| DW-7.2 | test_DW_7_2_* (5 tests), test_DW_7_2_full_frame_delivered_to_live_peer | Phase7PolicyTests, SocketWriteSafetyTests |
| DW-7.3 | test_DW_7_3_* (3 tests) | StartupSafetyTests |
| DW-7.4 | test_DW_7_4_* (2 tests) | StartupSafetyTests |
| DW-7.5 | test_DW_7_5_* (2 tests) | ActorMainSyncTests |
| DW-7.6 | test_DW_7_6_slot_reservation_rejects_inflight_and_installed | Phase7PolicyTests |
| DW-7.7 | test_DW_7_7_messaging_timeout_policy_is_sane, test_DW_7_7_make_app_element_does_not_crash | Phase7PolicyTests |
| DW-7.8 | test_DW_7_8_* (3 tests) | Phase7PolicyTests, MSSReprobeTests |
| DW-7.9 | test_DW_7_9_* (2 tests) | Phase7PolicyTests |
| DW-7.10 | test_DW_7_10_* (2 tests) | BFDExecutorDeadlockTests |
| DW-7.11 | test_DW_7_11_refuse_sentinel_frame, test_DW_7_11_accepts_real_frame | Phase7PolicyTests |
| DW-7.12 | test_DW_7_12_* (3 tests) | Phase7PolicyTests |
| DW-7.13 | test_DW_7_13_* (4 tests) | Phase7PolicyTests |
| DW-7.14 | test_DW_7_14_* (4 tests) | LayoutCycleDeferralTests |

- [x] All DW items have corresponding automated tests that ran in Step 0
- [x] Test coverage matches the "Backend 100%" level — every DW item has at least one test and the named test files (SocketWriteSafetyTests, StartupSafetyTests, MSSReprobeTests, BFDExecutorDeadlockTests, Phase7PolicyTests) are present and passing

---

## Dead Code

None found in the reviewed files.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `writeQueue` (serial) prevents frame interleaving; `socketQueue` with `.barrier` serializes `clientSockets` mutations; `observerCreationInFlight` slot reservation prevents TOCTOU. No lock-order cycle: `socketQueue.sync → sendMessage → writeQueue.sync` is the only nesting; `writeQueue` never calls back into `socketQueue`. |
| Error Handling | PASS | EPIPE/ECONNRESET/ENOTCONN/EBADF all mapped to `.disconnected`; EINTR/EAGAIN retried; open() failure logged with errno; MSS failure logged + re-probe triggered after threshold. No empty catch blocks. |
| Resources | PASS | DispatchSource cancel handler closes fd (`close(fd)` in `setCancelHandler`). FullWrite holds no resources. AX observer stopped before dict removal. |
| Boundaries | PASS | `payloadFlags` only appends flags for keys present in `valueFlags` allowlist; `writeBuffer` capacity checked (`if n >= cap { return }`) in all write helpers. `TerminalFramePolicy.threshold` guards sentinel detection. |
| Security | PASS (with note) | Notify params do not reach a shell — they route through `CommandExecutor → GridCommandRouter.dispatch()`, an internal tokenizer. `SO_NOSIGPIPE` on accepted sockets prevents signal-based DoS. See note below. |

---

## Notes (non-blocking)

1. **Notify payload quoting (minor injection surface):** `payloadFlags` wraps values in `"..."` for the internal command tokenizer. If a socket-supplied value contains embedded `"` characters, the tokenizer would split the quoted token early, potentially injecting extra positional tokens into the parsed command. Since the target is an internal router (not a shell), the blast radius is confined to misbehavior in grid-server's own command handling — not OS-level command injection. The `valueFlags` allowlist (`["title", "body", "priority", "source", "id"]`) limits the params that can participate. Stripping or escaping embedded `"` characters in `payloadFlags` before quoting would fully close this.

2. **`broadcast()` lock nesting:** `broadcast()` acquires `socketQueue.sync` and inside calls `sendMessage()` which acquires `writeQueue.sync`. This is a two-queue nesting. No deadlock currently because `writeQueue` never calls back into `socketQueue`. If future code adds a `socketQueue` acquisition inside `writeQueue`, deadlock is possible. A comment noting the nesting constraint would help future maintainers.

3. **BFDExecutor `readGroup.wait()` after `waitUntilExit()`:** The ordering is `waitUntilExit()` → `readGroup.wait()`. Because `readDataToEndOfFile()` returns only when the pipe is closed (which happens at/after process exit), this is safe — the readers always finish after `waitUntilExit` returns. The existing comment documents this correctly.

---

## Issues (if FAIL)

None.

**VERDICT: PASS**
