# Review: Phase 1 - Waiting Notify

## Executed Results (Step 0)
- Test suite: `cd grid-notify && swift build && swift test` → **93 tests, 0 failures**; the 12 `TmuxWaitingPolicyTests` all passed.
- Build/typecheck: `swift build` → exit 0, "Build complete!" (Swift compiles + type-checks in one pass; the AppDelegate actor/AppKit wiring type-checks).
- Lint: no separate linter configured for this SwiftPM package; the compiler is the type/diagnostic gate and is clean.

## Requirement Fulfillment

### DW-1.1
PREMISE:  `TmuxWaitingPolicy.diff` returns `newlyWaiting` = `.waiting` targets absent from `previousWaiting`, and `waitingNow` = all currently-`.waiting` targets.
EVIDENCE: TmuxWaitingPolicy.swift:29-34; test TmuxWaitingPolicyTests.swift:43-53.
TRACE:    windows=[active work:0, waiting work:1, running work:2], previousWaiting=[] → filter to `.waiting` = [work:1] → waitingNow={work:1}; newlyWaiting=[work:1] (not in previous). Test asserts `newlyWaiting.map(\.target)==["work:1"]` and `waitingNow==["work:1"]`.
VERDICT:  PASS

### DW-1.2
PREMISE:  A target waiting on two consecutive diffs appears in `newlyWaiting` only the first time (dedupe).
EVIDENCE: TmuxWaitingPolicy.swift:32 (`!previousWaiting.contains`); test :59-68.
TRACE:    diff1(prev=[], [waiting work:0]) → newly=[work:0], waitingNow={work:0}. diff2(prev={work:0}, [waiting work:0]) → work:0 in prev → newly=[]; waitingNow still {work:0}. Test asserts second.newlyWaiting empty, waitingNow=={work:0}.
VERDICT:  PASS

### DW-1.3
PREMISE:  A target that leaves `waiting` then re-enters appears in `newlyWaiting` again (re-arm).
EVIDENCE: TmuxWaitingPolicy.swift:31-32 (waitingNow recomputed each call from current windows only); test :74-87.
TRACE:    d1(prev=[],waiting)→newly=[work:0],now={work:0}; d2(prev={work:0},active)→now={} (work:0 not `.waiting`, drops); d3(prev={},waiting)→newly=[work:0]. Test asserts d3 re-fires.
VERDICT:  PASS

### DW-1.4
PREMISE:  viewModel does NOT invoke `onWaitingEntered` on first `load(_:)` even when windows already `.waiting`; DOES on a subsequent transition.
EVIDENCE: TmuxDashboardViewModel.swift:94-98 (`guard didBaseline` returns after setting flag and advancing previousWaiting); test :121-134.
TRACE:    load1([waiting work:0]) → detectWaitingTransitions sets previousWaiting={work:0}, didBaseline false → sets true, returns, no emit. load2([waiting work:0, waiting work:1]) → diff(prev={work:0}) → newly=[work:1] → didBaseline true → emits [work:1]. Test asserts first load emits nothing, second emits exactly [work:1].
VERDICT:  PASS

### DW-1.5
PREMISE:  On a real transition viewModel invokes `onWaitingEntered` exactly once per entered window; emission helper builds GridNotification with title "<target> needs input", body=summary, detailCmd="tmux capture-pane -pt <target> -S -200".
EVIDENCE: TmuxDashboardViewModel.swift:100-103 (single `onWaitingEntered?(result.newlyWaiting)` call, only when non-empty), :119-127 (`makeWaitingNotification`); tests :139-167.
TRACE:    Baseline load(active) → no emit. load(waiting work:0, waiting work:1) → newly=[work:0,work:1] → one callback carrying both windows; re-load same → newly=[] → no emit. Helper: window(target=work:0, summary="claude waiting...") → title="work:0 needs input", body="claude waiting...", detailCmd="tmux capture-pane -pt work:0 -S -200", source="tmux", action=nil. Tests assert all four fields + nil action, and once-per-window emission.
VERDICT:  PASS
Note: "exactly once per entered window" is realized as one callback invocation containing the array of newly-entered windows (the AppDelegate then makes one notification per element), not one callback per window. The DW wording is satisfied: each entered window is surfaced exactly once and produces exactly one notification (see DW-1.5b path).

### DW-1.5b
PREMISE:  AppDelegate wiring posts the GridNotification to NotificationStore (crosses actor/AppKit boundary); compiles; staying-waiting does not double-post while re-entry does.
EVIDENCE: AppDelegate.swift:181-191 (`vm.onWaitingEntered` maps windows → notifications and `await store?.add` inside a `Task`); store idempotency NotificationStore.swift:148-156; fresh-id rationale TmuxDashboardViewModel.swift:119-121; tests :171-177 (distinct ids), :183-195 (store.add persists). Compilation proven by clean `swift build`.
TRACE:    onWaitingEntered([work:0]) → makeWaitingNotification → id "tmux-waiting-work:0-<uuid>" → Task{ await store.add(n) } persists (test asserts `store.get(id)` returns title "work:0 needs input", source "tmux"). Staying-waiting: detectWaitingTransitions yields newly=[] so callback never fires → no double-post. Re-entry: diff re-arms (DW-1.3) → callback fires with a fresh UUID id → store.add inserts a new entry rather than dedup-dropping (distinct-id test confirms ids differ). The `[weak self]` capture and `store` snapshot are correct; emission off MainActor via `Task` to the NotificationStore actor is sound.
VERDICT:  PASS

### DW-1.6
PREMISE:  `viewModel.waitingCount` equals number of currently-`.waiting` windows after a `load(_:)`.
EVIDENCE: TmuxDashboardViewModel.swift:109-113 (reduces over @Published sessions, counting `.waiting`); tests :200-219.
TRACE:    load([waiting,active,waiting,running]) → sessions populated → waitingCount = 2. Empty data → 0, no emit, no crash. Tests assert both.
VERDICT:  PASS

**All requirements met:** YES

## Test-DW Coverage
- [x] All DW items have corresponding tests that ran in Step 0 (DW-1.1..1.6 + 1.5b each have `test_DW_1_x` cases, all passing).
- [x] Coverage matches the stated level: pure-logic seams (`diff`, baseline/dedupe/re-arm gating, `makeWaitingNotification`) unit-tested off the AppKit/actor boundary; the store-post path covered by an integration test (`test_DW_1_5b_store_add_persists_built_notification`).

Edge cases (all listed cases verified by an executed test):
| Edge case | Test | Result |
|---|---|---|
| First load already waiting → baseline, no notification | test_DW_1_4 / test_DW_1_6_empty + test_DW_1_5 baseline | PASS |
| Stays waiting across N loads → notified once | test_DW_1_2, test_DW_1_5 (third load) | PASS |
| Leaves then re-enters → re-armed | test_DW_1_3 | PASS |
| Window/session disappears while waiting → drops, no crash | test_disappearing_window_drops_and_rearms | PASS |
| Multiple windows enter in one load → one notification each | test_multiple_windows_enter_in_one_load, test_DW_1_5 | PASS |
| Empty TmuxStatusData → empty set, no emission, no crash | test_DW_1_6_empty_data_zero_count | PASS |

## Dead Code
None found. No unused imports, no unreachable code after the early returns in `detectWaitingTransitions` (both guards fall through to live code), no debug/commented-out blocks in the reviewed files.

## Correctness Dimensions
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `onWaitingEntered` invoked on MainActor (viewModel is `@MainActor`); store crossing is via `Task { await store?.add }` to the `NotificationStore` actor — correct isolation hop. `[weak self]`/`[weak vm]`/`[weak driver]` avoid retain cycles. No data race demonstrable. |
| Error Handling | PASS | Status file treated as external input; `TmuxStatusKind` decode is lenient (unknown→.idle, TmuxStatusModel.swift:41-45), `activity` decodeIfPresent. Empty/missing data handled (empty-data test). No empty catch blocks in scope. |
| Resources | N/A | Phase-1 reviewed code holds no file handles/locks/connections; the diff/viewModel are pure-state. (Driver/watcher lifecycle is Phase 4/5.) |
| Boundaries | PASS | Empty windows array → empty sets (no crash); duplicate targets collapse into a Set deterministically; `newlyWaiting` preserves input order for deterministic emission. Empty-collection tests pass. |
| Security | PASS | `detailCmd` interpolates `window.target` from the AI-written status file into a shell string. This is unchanged trust posture from the existing `openDetailCommand` (same interpolation pattern already shipped) and no DW/edge-case lists input sanitization as a requirement; flagged as a Note, not a defect. |

## Notes (non-blocking)
1. Command-injection surface (design observation, not a FAIL): `makeWaitingNotification` builds `detailCmd = "tmux capture-pane -pt \(window.target) -S -200"` from the status-file `target`, which originates from a headless Claude process. If that file were adversarially controlled, the string could carry shell metacharacters when later executed. No requirement in this phase asks for sanitization, and the identical pattern already exists in `openDetailCommand` (TmuxDashboardViewModel.swift:156-158), so this is consistent with the established codebase posture — worth tracking if the detail-exec path ever runs untrusted input through a shell.
2. APOSD depth: `TmuxWaitingPolicy.diff` is a deep, single-method pure seam hiding the dedupe/re-arm logic behind one call; the viewModel owns the mutable `previousWaiting`. Clean separation of decision vs. state. No classitis.
3. DW-1.5 emission shape: one callback carries the array of newly-entered windows rather than one callback per window. Equivalent in observable effect (one notification per window via AppDelegate.swift:183) and arguably the better interface; called out only because the DW says "exactly once per entered window."

## Issues (if FAIL)
None.

**Verdict: PASS**
