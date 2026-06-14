# Discovery + Design: Phase 7 - Silent errors, crash safety & infra

## Files Found
- `SocketServer.swift` — raw `send()`, no per-socket write serialization, no `SO_NOSIGPIPE` (#1, #46)
- `CrashReporter.swift` — `installSignal(SIGPIPE)` in fatal list (#1)
- `MessageHandler.swift` — `handlers` dict written after `start()`; `buildCommand` drops notify payload; 10 notify RPCs (#49, #22)
- `main.swift` — `Task { await gridState.load() }` unordered vs wiring (#45)
- `StateManager.swift` — `removeObserver` `main.sync` (#44); `createObserver` TOCTOU (#33); `getAXProperties`/`initializeFocusState` create app elements with no messaging timeout (#34); `handleSystemWoke` never resets MSS cache (#36)
- `MSSClient.swift` — `resetAvailabilityCache()` has zero callers (#36)
- `WindowManipulator.swift` — `getAXElement` creates app element w/o timeout (#34); `show()` path
- `BFD/BFDManager.swift` — `startConfigWatcher` opens fd once, never re-arms (#37)
- `BFD/BFDExecutor.swift` — `waitUntilExit()` before reading pipes (#38)
- `BFD/BFDKeyHandler.swift` — blacklist/appHotkeys keyed on `localizedName` (#47)
- `Grid/GridTerminalManager.swift` — `show()` ignores AX failure, flips state unconditionally; `hide()` can persist off-screen sentinel (#39)
- `Grid/GridCommandRouter.swift` — `handleNotify` ignores `cmd.action`; `handleLayout` cycle/previous wipes state before apply (#22, #58)
- `Grid/GridState.swift` — `cycleLayout`/`previousLayout` call `setCurrentLayout` (the wipe) eagerly (#58)
- `Grid/GridApply.swift` — `applyLayoutBody` step 13 already commits `setCurrentLayout` on layout switch (#58 target home)

## Current State
- Crash reporter installs 6 fatal signals incl. SIGPIPE; handler `_exit`s. Accepted sockets get no socket options; replies via single raw `send`.
- `MessageHandler.handlers` mutated lock-free; `registerGridHandlers` runs after `socketServer.start()` in `main.swift`.
- `removeObserver` blocks the actor's cooperative thread via `DispatchQueue.main.sync`; `rebuildAXObservers` already shows the correct `await MainActor.run` pattern.
- `createObserver` reserves its dict slot only inside a fire-and-forget `Task { @MainActor }`, after `observe()` — a second call for the same pid in that window double-registers; `addApplicationObserver` overwrites without stopping the displaced observer.
- No `AXUIElementSetMessagingTimeout` anywhere (grep: 0 hits). App elements created at StateManager:348, 578, 2172 and WindowManipulator:58.
- `MSSClient` caches availability permanently; `resetAvailabilityCache()` uncalled.
- BFD watcher dies on atomic rename; executor deadlocks on >64KB output; blacklist matches display name not bundle id.
- Terminal `show()` is `async -> Void`, flips `isHidden`/opacity/focus regardless of AX success; `hide()` saves whatever the current (possibly off-screen) frame is.
- `@notify` always toggles. `grid-notify` is a SEPARATE SPM package (not a `grid-server` dependency, not built by `swift test`); it only observes `com.thegrid.notify.toggle`.
- `handleLayout` cycle/previous: `gridState.cycleLayout` → `setCurrentLayout` wipes cells/focus BEFORE `applyLayout`; a throwing apply leaves the space wiped.

## Gaps
| # | Plan assumption | Reality | Resolution |
|---|---|---|---|
| #22 | "forward push/list/dismiss payloads" | grid-notify only listens for `toggle`; push/etc. arrive via a pipe, not distributed notifications; grid-notify is out of this worktree's build | Fix the SERVER contract: `buildCommand` forwards notify params; `handleNotify` switches on action and posts DISTINCT distributed notifications (show/hide/toggle + per-action names carrying payload userInfo). Unit-test the action→notification mapping. End-to-end GridNotify consumption is UAT/grid-notify follow-up. |
| #34 | timeout "0.5s" | Three+ app-element creation sites | One shared `makeAppElement(pid:)` helper sets the timeout; replace raw `AXUIElementCreateApplication` at the hot sites. Pure helper testable via `AXMessagingTimeoutPolicy.timeoutSeconds`. |
| #58 | "move cycleLayout into applyLayoutBody" | `applyLayoutBody` step 13 already commits the layout on switch | Router computes target id via PURE `GridState.computeCycleLayout/computePreviousLayout` (no mutation); passes id to `applyLayout`; body's step-13 commit is the only writer. The eager `setCurrentLayout` wipe is removed from cycle/previous. |

## Code Standards
- Swift actors / `await MainActor.run` for shared mutable state — never `DispatchQueue.main.sync` from an actor (#44).
- `jlog` codes `warn.<scope>.<reason>` / `err.<scope>` / `<scope>.<event>`.
- Comments on their own line.
- `[weak self]` + `guard let self` in escaping closures; never `Task{}` back into the owning actor.
- Extract pure predicates as `static` helpers, unit-test off the OS boundary.
- Robustness domain (log-and-continue / surface) EXCEPT SIGPIPE (correctness — server must survive).

## Test Infrastructure
- XCTest, `@testable import GridServer`, files named `*Tests.swift` in `grid-server/Tests/GridServerTests/`.
- Pure-policy pattern established (`SpaceMigrationPolicy`, `FocusOwnershipPolicy`, `WindowAdoptionPolicy`, `BordersPolicy`, `HeartbeatScheduler`). Tests name `test_DW_7_X_...`.
- Integration tests use fakes for `Ports/` protocols.
- Baseline: 242 green. Build warnings other than `main.swift:8` + ApplicationObserver as-casts are failures.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-7.1 (#1) | SO_NOSIGPIPE on accepted sockets + SIGPIPE off fatal list; disconnect mid-reply → EPIPE handled, server up | COVERED | `[U]` `test_DW_7_1_sigpipe_not_in_fatal_signal_list` (CrashReporter.fatalSignals omits SIGPIPE); `[U]` `test_DW_7_1_accept_sets_nosigpipe_option` (SocketOptionsPolicy applies SO_NOSIGPIPE). Live survival = `[M]` UAT |
| DW-7.2 (#46) | per-socket serialized full-write loop; no interleaved/short frames | COVERED | `[U][D]` `test_DW_7_2_full_write_loop_handles_short_write` (FullWrite.writeAll loops on partial returns); `test_DW_7_2_full_write_loop_handles_eintr`; `test_DW_7_2_full_write_reports_epipe` |
| DW-7.3 (#49) | handlers registered before start (or guarded); no startup 404 | COVERED | `[I]` `test_DW_7_3_handlers_registered_before_start` (MessageHandler.isReady false until finalize, true after; SocketServer rejects with retryable error pre-ready) |
| DW-7.4 (#45) | GridState.load() awaited before wiring | COVERED | `[U]` `test_DW_7_4_load_completes_before_wiring_flag` via `StartupSequencer` ordering token; integration `[I]` asserting load runs before reconciler registration callback fires |
| DW-7.5 (#44) | removeObserver uses await MainActor.run | COVERED | `[I]` `test_DW_7_5_remove_observer_is_async_no_main_sync` (removeObserver is `async`; stop runs without deadlock when called from actor) |
| DW-7.6 (#33) | registration reserves slot synchronously; replaced observer stopped | COVERED | `[I][D]` `test_DW_7_6_duplicate_register_reserves_slot` (second createObserver for same pid is a no-op while first in-flight); `test_DW_7_6_replaced_observer_stopped` |
| DW-7.7 (#34) | AXUIElementSetMessagingTimeout set on app elements | COVERED | `[U]` `test_DW_7_7_messaging_timeout_policy` (timeoutSeconds within bounds); `[I]` `test_DW_7_7_make_app_element_sets_timeout` (helper used; no crash) |
| DW-7.8 (#36) | resetAvailabilityCache on wake; re-probe on repeated mss.fail | COVERED | `[U][D]` `test_DW_7_8_reset_clears_cache` (after reset, isAvailable re-probes); `[U]` `test_DW_7_8_reprobe_policy_on_repeated_fail` (MSSReprobePolicy.shouldReprobe at threshold) |
| DW-7.9 (#37) | watcher re-arms on atomic rename + logs open failure | COVERED | `[U]` `test_DW_7_9_watcher_rearm_decision` (ConfigWatcherPolicy.shouldRearm on .rename/.delete); `[U][D]` open-fail logs |
| DW-7.10 (#38) | reads both pipes concurrently; verbose command no deadlock | COVERED | `[I][D]` `test_DW_7_10_large_output_no_deadlock` (BFDExecutor against a >64KB-emitting shell command completes < timeout) |
| DW-7.11 (#39) | show() hard-fails on AX-nil / setFrame-false; refuses sentinel frame | COVERED | `[U][D]` `test_DW_7_11_refuse_sentinel_frame` (TerminalFramePolicy.isOffScreenSentinel); `[I][D]` `test_DW_7_11_show_aborts_on_ax_failure` (fake manipulator returns nil/false → show returns false, state not flipped) |
| DW-7.12 (#47) | blacklist/overrides match bundleIdentifier | COVERED | `[U][D]` `test_DW_7_12_bundle_id_match_predicate` (AppMatchPolicy matches bundle id, and name for back-compat) |
| DW-7.13 (#22) | @notify dispatches on cmd.action + forwards payload | COVERED | `[U]` `test_DW_7_13_notify_action_to_notification_mapping` (NotifyActionPolicy: show/hide/toggle/push/dismiss → distinct names); `[U]` `test_DW_7_13_buildcommand_forwards_notify_params` |
| DW-7.14 (#58) | layout-cycle wipe deferred into applyLayoutBody | COVERED | `[U]` `test_DW_7_14_compute_cycle_no_mutation` (computeCycleLayout returns id without wiping cells); `[I][D]` `test_DW_7_14_thrown_apply_preserves_state` (throwing apply leaves prior cells intact) |

**All items COVERED:** YES (DW count = 14 = prompt count)

## Design Decisions

### Error Reduction (aposd) — technique analysis
| Error Condition | Technique | Gate Check | Reasoning |
|---|---|---|---|
| Client disconnect mid-write (#1) | Define out (SO_NOSIGPIPE) → send returns EPIPE | PASS | Redefine: write to a dead socket yields a return code, not a signal. Existing `sock.err` branch handles it. Server-level correctness (must survive). |
| Short/partial socket write (#46) | Mask (full-write loop inside writeAll) | PASS — caller has no useful per-chunk response | Loop handles EINTR/EAGAIN/partial; surfaces only terminal EPIPE/error via `sock.err`. |
| Startup 404 window (#49) | Define out (register before accept) + Aggregate (single readiness flag) | PASS | Ordering removes the race; readiness flag is the single guard. |
| AX IPC to hung app (#34) | Mask (messaging timeout bounds the block) | PASS — no caller response to a beachball | Timeout converts an indefinite freeze into a fast `kAXErrorCannotComplete`, logged. |
| MSS permanently unavailable (#36) | Define out (reset on wake) + Aggregate (re-probe on repeated fail) | PASS | Removes the "cached forever" terminal state. |
| BFD watcher dead inode (#37) | Define out (re-arm on rename/delete) | PASS — normal editor behavior, not an essential error | Re-open restores the invariant "config edits reload". |
| Pipe deadlock (#38) | Define out (read before/concurrent with wait) | PASS | Mirrors the documented `runProcess` correct pattern. |
| Terminal AX failure (#39) | Expose (show returns false; do not flip state) + Define out (refuse sentinel frame) | PASS — caller (toggle) needs to know it failed | Essential error: a stranded focused off-screen window steals all keystrokes. Fail fast. |
| Layout-cycle wipe before throwing apply (#58) | Define out (never pre-commit; single writer in body) | PASS — `applyLayoutBody` already owns the commit | Removes the "wiped-then-thrown" state entirely. |
| Notify action collapse (#22) | Expose (distinct notification per action) | PASS — actions are NOT handled identically (NA: not aggregatable) | show ≠ hide ≠ push; forward payload. |

### Pull-complexity-down decisions
- `#34`: one `makeAppElement(pid:)` helper sets the timeout once; callers do less (PD-1/2/3 all YES — timeout is intrinsic to "talk to an app's AX server").
- `#46`: `FullWrite.writeAll(fd:bytes:)` owns the loop; `sendMessage` does less.
- `#58`: router passes a computed id; the wipe logic lives in one place (body), not split across router + state.

### New / changed seams
- `CrashReporter.fatalSignals: [Int32]` (static) — install loop reads it; SIGPIPE removed. Process also `signal(SIGPIPE, SIG_IGN)` as belt-and-suspenders.
- `SocketOptionsPolicy.applyClientOptions(fd:)` — sets `SO_NOSIGPIPE`; called on each accepted socket.
- `FullWrite.writeAll(fd:_:) -> WriteResult` + per-socket serial `DispatchQueue` write funnel in SocketServer.
- `MessageHandler.finalizeRegistration()` + `isReady` guard; `main.swift` registers handlers before `start()`.
- `StartupSequencer` token (load-before-wire ordering) + `await gridState.load()` before wiring in `main.swift`.
- `StateManager.removeObserver` → `async`, `await MainActor.run`.
- `createObserver`: reserve a `.reserved` placeholder in `applicationObservers` synchronously; `addApplicationObserver` stops a displaced live observer.
- `makeAppElement(pid:)` free function + `AXMessagingTimeoutPolicy`.
- `MSSReprobePolicy` + `resetAvailabilityCache()` call in `handleSystemWoke` + re-probe on repeated `mss.fail`.
- `ConfigWatcherPolicy.shouldRearm(eventFlags:)` + watcher re-arm in BFDManager.
- BFDExecutor: concurrent pipe reads (background-thread readers started before `waitUntilExit`).
- `AppMatchPolicy.matches(config:bundleID:name:)` in BFDKeyHandler.
- `GridTerminalManager.show(...) -> Bool` + `TerminalFramePolicy.isOffScreenSentinel`.
- `NotifyActionPolicy` (action → distributed-notification name + whether payload) + `buildCommand` notify params; `handleNotify` switches on action.
- `GridState.computeCycleLayout/computePreviousLayout(spaceID:availableLayouts:) -> (id, index)` pure (no mutation); router uses them; eager wipe removed.

All pure predicates collect in `Grid/Phase7Policy.swift` (one file, several small `enum`-namespaced static helpers) except where a natural home exists (`CrashReporter.fatalSignals`, `GridState.compute*`).

## Prerequisites
- [x] Required files exist
- [x] Dependencies available (P1 CommandExecutor, generation counter present)
- [x] 242 baseline green

## Recommendation
BUILD — 14 independent one-file fixes + shared pure predicates. Landable in one pass; each DW has a unit/integration test, OS-level survival items (#1 live, #34 freeze, #38 deadlock proven via large-output integration) flagged UAT where noted.
