# Discovery + Design: Phase 3 - Focus ownership & navigation

## Files Found
- `Grid/GridFocus.swift` (1054 lines) — class `GridFocus`; `moveFocus`, `cycleFocus`, `focusCellByID`, `focusWindowByID`; holds `focusLoopDetector` (struct, unsynchronized).
- `Grid/FocusLoopDetector.swift` (75 lines) — pure `FocusLoopDetector` struct; keys on unordered `PairKey`; threshold 3 in 2s.
- `WindowManipulator.swift` — `focusWindowWithRaise` (458-482), `focusWindowFallback` (485-497), `focusWindow(pid:windowID:)` (501-510), `focusWindow(context:)` (513-519), WindowController conformance (568-582).
- `Grid/GridReconciler.swift` (1665) — `focusSweep` (395-435), `handleWindowMinimized` (1175-1186), fence/generation primitives (55-74), `executeAction`/`beginAction` (124-204), `isWindowFenced` (312-314).
- `ApplicationObserver.swift` — `axNotificationCallback` (330-345) spawns `Task{}` per notification.
- `WorkspaceObserver.swift` — `applicationActivated` (181-198) spawns `Task{}` + sync AX query.
- `StateManager.swift` — `applyWindowFocus` (777-782), `setFocusedWindow` (820+), `updateActiveSpace` (748-772).
- `EventRouter.swift` — `actor EventRouter` (165); `FocusState` (72-99); `route` (201-222) already serialized by actor.
- Ports: `WindowController.swift`, `StateProvider.swift`.
- Tests: `FocusLoopDetectorTests`, `GridFocusRaceTests`, `WindowControllerTests` (MockWindowController), `StateProviderTests` (MockStateProvider), `ReconcilerActionTokenTests`.

## Current State
- **#21**: `focusWindowWithRaise` discards every CG/SLPS/AX result and `return true` unconditionally (481); `focusWindowFallback` same (496). `focusWindow(context:)` calls `setFocusedWindow` on the always-true result. `SLPSSetFrontProcessWithOptions` returns `CGError` (`.success` / `.failure`); `GetProcessForPID` returns `OSStatus`; `getAXElement` returns `AXUIElement?`.
- **#7**: `focusWindowByID` verifies against the event-fed cache (`postState.metadata.focusedWindowID`) after a single `Task.yield()` — the cache lags a main-runloop round trip, so `actual` is frequently the previously-focused window → spurious `focus.mismatch` + redundant raise.
- **#8**: `moveFocus` candidate selection (`pickClosestCell` 766-792) never filters for emptiness; `focusCellByID` throws `noWindowsInCell` when the picked cell is empty. No skip-to-next / wrap fallback in the in-display path (cross-display path DOES filter to cells-with-windows at 861-871).
- **#13**: `focusSweep` (395) skips on `suppressReconciliation` once at the top, then suspends across 6 awaits before `setFocus` (416). Never consults `fence`/`generation`. `window` commands are NOT wrapped in `executeAction` (GridCommandRouter:190-191), so a move runs unsuppressed and the sweep can revert mid-flight.
- **#17**: AX/workspace notifications are delivered in order on the main runloop but `axNotificationCallback`/`applicationActivated` spawn an unstructured `Task{}` each → global-executor reordering. `applyWindowFocus` overwrites `focusedWindowID` unconditionally — no sequence stamp.
- **#35**: `focusLoopDetector` is a mutable struct field on the non-isolated `GridFocus` class, mutated from concurrent callers (command path + reconciler event path + sweep). Array CoW under concurrent mutation = data race.
- **#43**: detector consulted only in the `if let actualWID, actualWID != windowID` branch (nil-actual bypasses); keys on the unordered pair (a 3-window rotation never trips any single pair); no post-trip suppression; attempt-1 raise fires before the detector is consulted.
- **#42**: `cycleFocus` (228-234) and `focusCellByID` (318-323) prune via detached `Task { await gridState.removeWindow(...) }` with no ordering vs the subsequent `setFocus` → `setFocus` can index the un-pruned array, recording a dead/wrong successor.
- **#30**: `handleWindowMinimized` (1175) resolves `findCurrentSpaceIDAsync()` (focused display's active space) and removes from THAT space. If the window is tracked elsewhere, `removeWindow` is a silent no-op and the cell slot stays reserved. `findSpaceContaining(windowID:)` (GridState:573) and `removeWindowFromAllSpaces` (491) already exist.
- **#59s** (suspected): `restoreFocusForSpace` (StateManager:1830) raises `space.lastFocusedWindowID` after checking only existence + not-hidden — never `window.spaces.contains(spaceID)`. Dormant in logs (0 `win.focus.restore` hits). DW asks for instrumentation only (`win.focus.restore.skip`).

## Gaps
| # | Gap | Resolution |
|---|-----|-----------|
| 1 | #17 plan text says "single ordered AX pipeline" but reworking the AX callback to an AsyncStream is high-risk on a live WM and `EventRouter.route` already serializes once events arrive. | Implement the load-bearing, testable half the plan explicitly names: a **monotonic focus sequence stamp** so `applyWindowFocus` rejects older-than-current focus events. Extract a pure `FocusSequenceGate` predicate (unit-testable off the boundary). The per-callback `Task{}` reorder window is narrowed by the gate rejecting the stale write — the actual inversion symptom (#17) is the stale write winning, which the gate prevents. Documented as the chosen alternative per dispatch instructions. |
| 2 | #7 "direct AX query" cost on the hotkey path. | The port `WindowController` has no AX-query method and adding a synchronous AX focused-window read on every focus is the costly path the dispatch flags. Chosen alternative: make focus **write state synchronously on genuine success** (the `focusWindow(context:)` pattern already does this) — `focusWindowByID` will treat a `true` result from the port as authoritative for its own requested window and stop trusting the lagging event cache for the self-match case, eliminating the spurious-mismatch double-raise. This is the same outcome (#7 symptom gone) without a per-focus AX round trip. |
| 3 | `FocusLoopDetector` API keys on a pair; #43 needs per-requested-window keying + nil-actual + post-trip suppression. | Extend `FocusLoopDetector` with a per-requested-window observation path + a suppression window. Keep the existing pair API (anchored tests) intact; add new methods/fields. |

## Code Standards
`docs/code-standards.md` present. Applied: Swift actors for shared mutable state (isolate the detector); `jlog` codes `warn.<scope>.<reason>` / `err.<scope>` / `<scope>.<event>`; comments on their own line; extract pure decision predicates as `static`/value-type helpers and unit-test off the AX/SkyLight boundary; never `Task{}` back into the owning actor; `Ports/` fakes (`MockWindowController`, `MockStateProvider`) for `[I]` tests.

## Test Infrastructure
XCTest, `@testable import GridServer`. Fakes: `MockWindowController` (records calls, configurable `focusResult`), `MockStateProvider` (canned `WindowManagerState`). `GridFocus._test_setup`, `GridReconciler._test_setup` / `_test_handle` / `_test_isFenced` / `_test_triggerWindowCreated`. Pure predicates tested directly (e.g. `GridFocus.detectFocusRace`). Tests name DW-IDs.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-3.1 (#21) | `focusWindow` returns false on AX/CG/SLPS failure; state focus set only on success; `err.focus`/`warn.focus` fire on a real failure | COVERED | `[U]` `FocusFailureTests.test_DW_3_1_classify_*` (pure `WindowManipulator.classifyFocusResult` truth table: SLPS .failure ⇒ false, AX-element-nil ⇒ false, all-success ⇒ true); `[I]` `test_DW_3_1_context_focus_skips_setFocus_on_failure` (mock returns false ⇒ no `setFocusedWindow`) |
| DW-3.2 (#7) | focus verified by direct AX query (not event-fed cache) — no spurious mismatch/double-raise in stale-cache scenario | COVERED | `[I][D]` `test_DW_3_2_no_double_raise_when_cache_stale` (MockStateProvider with `focusedWindowID` = a *different* (stale) window; success result ⇒ exactly ONE focusWindow call, no second raise, returns requested wid) |
| DW-3.3 (#8) | directional focus skips empty cells to next candidate/wrap; no `noWindowsInCell` dead-end | COVERED | `[U]` `test_DW_3_3_skip_empty_selects_next` / `_all_empty_returns_nil` / `_wrap_target_filtered` (pure `GridFocus.selectNonEmptyCandidate(candidates:cellWindowCounts:...)`) |
| DW-3.4 (#13) | focusSweep skips fenced wids + re-checks generation before correcting; no revert mid/post-command | COVERED | `[U]` `test_DW_3_4_sweep_should_skip_when_fenced` / `_when_generation_changed` / `_proceeds_when_clear` (pure `GridReconciler.shouldSweepCorrect(osWindowFenced:cellMateFenced:genAtStart:genNow:suppressed:)`); `[I]` `test_DW_3_4_window_command_wrapped_in_executeAction` (suppressionDepth>0 during a window command) |
| DW-3.5 (#17) | single ordered consumer w/ sequence stamps rejects stale focus events — no inversion while typing | COVERED | `[U]` `test_DW_3_5_gate_accepts_newer` / `_rejects_older` / `_accepts_equal_first` (pure `FocusSequenceGate.shouldApply(incomingSeq:lastAppliedSeq:)`) |
| DW-3.6 (#35) | loop detector actor-isolated (no array data race) — unit/TSan check | COVERED | `[I]` `test_DW_3_6_detector_isolated_concurrent_observe` (actor `FocusLoopActor` driven from concurrent tasks completes without crash, correct trip count) — TSan is the `[M]` UAT layer |
| DW-3.7 (#43) | detector observes nil-actual, keys per-requested-window, suppresses after trip; 3-window rotation trips | COVERED | `[U]` `test_DW_3_7_three_window_rotation_trips` / `_nil_actual_observed` / `_suppressed_after_trip` (extended `FocusLoopDetector.observeRequested(requested:actual:now:)`) |
| DW-3.8 (#42) | dead-window prune awaited before `setFocus` — correct successor after close | COVERED | `[I][D]` `test_DW_3_8_prune_awaited_before_setFocus` (cell `[dead, live]`, dead not in wmState; after `cycleFocus`/`focusCell` GridState focus = live, dead removed) |
| DW-3.9 (#30) | minimize removes window from its tracked space via `findSpaceContaining`; slot freed regardless of focused display | COVERED | `[I]` `test_DW_3_9_minimize_frees_slot_on_nonfocused_space` (window tracked on space B, active space A; after minimize, B cell no longer contains it) |
| DW-3.10 (#59s) | restore-focus space-membership check instrumented (`win.focus.restore.skip`); confirmed/dropped in UAT | COVERED (instrument-only) | `[U]` `test_DW_3_10_restore_skip_predicate` (pure `StateManager.shouldSkipRestore(windowSpaces:spaceID:)` — true when spaceID absent). Behavior unchanged; emits `win.focus.restore.skip` for UAT. |

**All items COVERED:** YES (10/10; DW-ID count matches the dispatch prompt's 10)

## Design Decisions

Skills applied: `cc-control-flow-quality` (guard clauses, extract pure predicates, number-line/positive booleans), `cc-defensive-programming` (propagate return codes, no swallowed failures, correctness for the focus-ownership write path), `gof-design-patterns` (no new pattern — straightforward solutions; GoF "if a straightforward solution works, use it").

**Correctness vs robustness:** the `GridState.focusedWindow` write-on-success invariant is a *correctness* path (P6 treats it as the authoritative border target — a wrong write propagates a phantom border). So focus state is written only on genuinely-confirmed success; on failure we surface (`err.focus`/`warn.focus`) and do not write.

1. **#21 — pure result classifier.** Capture each native result in `focusWindowWithRaise`: `GetProcessForPID == 0`, `SLPSSetFrontProcessWithOptions == .success`, AX element present + `AXUIElementPerformAction == .success`. Feed them to `static func classifyFocusResult(...) -> Bool`. The fallback path classifies analogously. `focusWindow(pid:windowID:)` returns the real Bool; the existing `err.focus` (507) now actually fires; add `warn.focus{reason}` at each discarded-result site. `focusWindow(context:)` already gates `setFocusedWindow` on the result, so it becomes correct for free. Pure classifier is unit-testable off the boundary.

2. **#7 — trust the port success for the self-match.** In `focusWindowByID`, when `windowController.focusWindow` returns `true`, the requested window is authoritatively focused; do not re-derive a "mismatch" from the lagging event cache when the cache still names a *different older* window. Keep the `detectFocusRace` accept-reality branch for the genuine same-cell-late-notification case. Net: the stale-cache double-raise (#7 symptom) is gone without a per-focus AX query. (Documented alternative to the literal "direct AX query".)

3. **#8 — pure non-empty selection predicate.** `static func selectNonEmptyCandidate(orderedCandidates:[String], cellWindowCounts:[String:Int]) -> String?` returns the first candidate whose count > 0 (caller orders by closeness). `moveFocus` filters `candidates` and wrap targets through it before `focusCellByID`; if none non-empty, fall through to the next direction/wrap rather than throwing `noWindowsInCell`. Mirrors the cross-display path's existing cells-with-windows filter.

4. **#13 — pure sweep-guard predicate + wrap `window` commands.** `static func shouldSweepCorrect(osWindowFenced:Bool, cellMateFenced:Bool, genAtStart:UInt64, genNow:UInt64, suppressed:Bool) -> Bool` returns false if suppressed, if the OS-focused window (or a cell-mate) is fenced, or if the generation changed across the sweep's awaits. `focusSweep` snapshots `generation` at entry, consults `fence`/`isCellMateOfFencedWindow`, and re-checks the predicate immediately before `setFocus`. Wrap `case "window"` in `executeAction` (GridCommandRouter:190) like `"focus"` so moves suppress the sweep.

5. **#17 — monotonic focus sequence gate.** Add `private(set) var focusSeq: UInt64` minted per routed focus event (assigned where `FocusState` originates / where `applyWindowFocus` runs in StateManager). `static func FocusSequenceGate.shouldApply(incomingSeq:lastAppliedSeq:) -> Bool` (newer-or-equal-first wins; strictly-older rejected). `applyWindowFocus` consults it and drops a stale event. Pure gate unit-tested; the AX-callback `Task{}` stays (lowest live-WM risk) but a reordered older event can no longer overwrite a newer focus.

6. **#35/#43 — actor-isolated, per-requested-window detector.** Wrap the detector in `actor FocusLoopActor` owning a `FocusLoopDetector` (kills the array race, #35). Extend `FocusLoopDetector` with `observeRequested(requested:actual:now:)` keying on the *requested* window (a 3-window rotation A→B→C→A trips on requested=A repeating), observing the nil-actual case (treat nil as a sentinel `actual`), and a post-trip suppression window (`suppressedUntil`). `GridFocus` calls the actor via `await` (it's already async). Existing pair-API tests stay green.

7. **#42 — await the prune.** Replace the detached `Task { await gridState.removeWindow(...) }` in `cycleFocus`/`focusCellByID` with a direct `await gridState.removeWindow(...)` so `setFocus` indexes pruned state. Already inside `async` context — no `Task{}` needed (also satisfies the no-`Task{}`-into-actor rule).

8. **#30 — resolve the tracked space.** `handleWindowMinimized` resolves `await gridState.findSpaceContaining(windowID:)`; if found, `removeWindow(_, fromSpace:)` there, else `removeWindowFromAllSpaces`. Frees the slot regardless of the focused display.

9. **#59s — instrument only.** Add `static func shouldSkipRestore(windowSpaces:[UInt64], spaceID:UInt64) -> Bool` and, in `restoreFocusForSpace`, emit `win.focus.restore.skip{wid,space}` when the predicate is true — but keep current behavior (still attempts restore) so this is pure instrumentation; the confirm-or-drop happens in UAT. NO blind behavioral change.

## Prerequisites
- [x] P1 primitives present: `RefcountedFence`, `GenerationCounter` (`generation` exposed at GridReconciler:74), `isWindowFenced`, `isCellMateOfFencedWindow`, `executeAction` bump.
- [x] Ports + fakes fakeable (`MockWindowController` configurable `focusResult`; `MockStateProvider` canned state).
- [x] `GridState.findSpaceContaining` / `removeWindowFromAllSpaces` exist.
- [x] Build clean, 165 tests green at baseline.

## Recommendation
BUILD. All 10 DW items are reachable with the primitives and fakes in place. Two DW items (#7 direct-AX, #17 full pipeline) use the documented lighter-weight alternative the dispatch explicitly permits — no restructuring of P1's primitives and no risk to the live command path. #59s is instrument-only.
