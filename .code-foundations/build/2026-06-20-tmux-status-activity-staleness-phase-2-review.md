# Review: Phase 2 - tmux per-window activity + staleness

## Executed Results (Step 0)
- Test suite: `cd /Users/r/repos/theGrid/grid-notify && swift test` → **104 tests, 0 failures** (exit 0). Baseline was 100 tests → +4 new tests, no regressions.
- Build: `cd /Users/r/repos/theGrid/grid-notify && swift build` → **Build complete!** (exit 0, no warnings in output).
- Lint/Typecheck: No separate linter in this Swift package; `swift build` is the typecheck/compile authority and is clean. Editor-index diagnostics intentionally disregarded per dispatch note.

## Requirement Fulfillment

### DW-2.1
PREMISE:  `TmuxWindow` (in TmuxStatusModel.swift) decodes an `activity` integer when present in the JSON, and defaults it to 0 when the key is absent (back-compat with older status files), without throwing.
EVIDENCE: TmuxStatusModel.swift:70 (`let activity: Int`), :84 (CodingKey `.activity`), :99 (`activity = try container.decodeIfPresent(Int.self, forKey: .activity) ?? 0`).
TRACE:    JSON window `{...,"activity":1718499994}` → `decodeIfPresent` returns `1718499994` → `window.activity == 1718499994`. JSON window with no `activity` key → `decodeIfPresent` returns nil → `?? 0` → `window.activity == 0`, no throw.
EVIDENCE (tests, ran in Step 0): `test_DW_2_1_windowDecodesActivityWhenPresent` (asserts 1718499994), `test_DW_2_1_windowActivityDefaultsToZeroWhenAbsent` (canonicalJSON omits activity on all windows → all 0), `test_DW_2_1_fullSampleDecodesAllFields` — all PASSED.
VERDICT:  PASS

### DW-2.2
PREMISE:  `TmuxDashboardViewModel.relativeAge(activity:now:)` returns nil for `activity == 0`, and otherwise the correct string: `<60s`→"now", `<3600s`→"Nm", `<86400s`→"Nh", else "Nd"; a negative diff → "now".
EVIDENCE: TmuxDashboardViewModel.swift:155–164. Guard `activity != 0 else return nil` (:156); `seconds = Int(now...) - activity` (:157); switch buckets `..<60`→"now", `..<3600`→"\(seconds/60)m", `..<86400`→"\(seconds/3600)h", default→"\(seconds/86400)d" (:158–163).
TRACE:    activity=0 → nil. now-30s → seconds=30 → `..<60` → "now". now-300s → seconds=300 → `..<3600` → 300/60=5 → "5m". now-7200s → 7200/3600=2 → "2h". now-172800s → 172800/86400=2 → "2d". Negative diff (activity in future) → seconds<0, `<0` is in `..<60` → "now" (no negative string). Boundaries: 59→"now", 60→"1m", 3599→"59m", 3600→"1h", 86399→"23h", 86400→"1d".
EVIDENCE (tests, ran in Step 0): `test_DW_2_2_relativeAgeFormatsBuckets` (nil@0, 30→now, 300→5m, 7200→2h, 172800→2d), `test_DW_2_2_relativeAgeBoundariesAndNegative` (all six boundaries + secondsAgo:-500→"now" + future epoch+10000→"now") — both PASSED.
VERDICT:  PASS

### DW-2.3
PREMISE:  `TmuxDashboardWindowRow` (in TmuxDashboardView.swift) renders the relative age when non-nil, without disturbing the existing window name / `*` active-marker / summary / waiting-row-highlight layout.
EVIDENCE: TmuxDashboardView.swift:254–275. The name+marker HStack is unchanged: `Text("\(window.index): \(window.name)")` (:255), `if window.active { Text("*") }` (:260–264), then `Spacer()` (:266), then the NEW age block guarded by `if let age = TmuxDashboardViewModel.relativeAge(activity: window.activity, now: Date())` rendering `Text(age)` as muted/textTertiary meta-sized (:270–274). Summary unchanged (:278–281). Waiting highlight unchanged: `rowBackground` (:226–230) + left accent overlay (:289–295) both still keyed off `isWaiting`/`isWaitingHighlight`.
TRACE:    window.activity==0 → relativeAge returns nil → `if let` is false → no age Text added → row identical to pre-Phase-2 layout. window.activity=epoch → age string non-nil → muted Text appears right-aligned after the Spacer, on the same HStack row as name+marker; summary and highlight untouched.
EVIDENCE (tests/observed): The age placement is desk-checkable SwiftUI layout (no automated view-render test exists or is feasible here). The pure helper it depends on (`relativeAge`) is fully covered by the DW-2.2 tests above; the nil→no-label branch is the exact same nil contract those tests assert. The waiting-highlight predicate it shares is covered by `test_DW_2_2_highlightPredicateTrueOnlyForWaiting`/`...FalseForNonWaitingKinds` (PASSED). Observed by code walk: name/`*`/summary/highlight code paths are byte-for-byte the prior layout with only an additive `if let age` block inserted after `Spacer()`.
VERDICT:  PASS

### DW-2.4
PREMISE:  `swift build` is clean and the full `grid-notify` test suite stays green (no regressions vs the prior 100-test baseline).
EVIDENCE: Step 0 — `swift build` → "Build complete!" exit 0; `swift test` → "Executed 104 tests, with 0 failures" exit 0.
TRACE:    Build invoked → 0 errors/warnings emitted. Suite invoked → 104/104 pass; 100→104 is +4 (the new Phase-2 tests), every prior test still present and green → no regression.
VERDICT:  PASS

### DW-2.5
PREMISE:  `docs/TMUX_DASHBOARD.md` documents the per-window `activity` field (int epoch) and the >300s staleness→idle behavior. (grug-memory half out of scope.)
EVIDENCE: docs/TMUX_DASHBOARD.md:158 (`"activity": 1718499994` in the schema JSON), :167–181 section "Per-window `activity` and staleness": describes activity as "Unix epoch (seconds) of the window's last pane output, taken from tmux's `#{window_activity}`" (:169–170), renders as relative age `now/Nm/Nh/Nd` (:170–171), back-compat absent→0→no age shown (:173–176), and the staleness gate: "any window whose last activity is more than **300 seconds** ago can never be reported as `active` or `running` — it is downgraded to `idle`" and "never flipped to `waiting`" (:178–181).
TRACE:    Reader opens doc → finds `activity` field in schema (int epoch) and a dedicated section stating the >300s → idle downgrade with the never-`waiting` carve-out → requirement documented.
EVIDENCE (observed): Doc content read directly in Step 1 (not a code-executable item; doc verification is the correct evidence form here).
VERDICT:  PASS

**All requirements met:** YES

## Edge Cases (same verdict standing as DW items)

| Edge case | Evidence | Verdict |
|-----------|----------|---------|
| JSON omits `activity` → `activity == 0`, no age, no decode failure | `decodeIfPresent ?? 0` (Model:99); `test_DW_2_1_windowActivityDefaultsToZeroWhenAbsent` PASSED; row `if let age` is false at 0 (View:270) | PASS |
| Test call sites building `TmuxWindow(...)` WITHOUT `activity` still compile | Memberwise init defaults `activity: Int = 0` (Model:113). Confirmed call sites: TmuxWaitingPolicyTests.swift:17 `window(...)` helper and TmuxDashboardTests.swift:409,419 omit activity. `swift build`/`swift test` both compiled and ran 104 tests → these sites compile. | PASS |
| `relativeAge` negative diff (clock skew) → "now", no crash/negative string | `seconds < 0` falls into `..<60` → "now" (VM:158–159); `test_DW_2_2_relativeAgeBoundariesAndNegative` asserts secondsAgo:-500→"now" and future epoch→"now" PASSED | PASS |
| waiting→notification path (TmuxWaitingPolicy / onWaitingEntered / badge + highlight) unchanged & passing | `detectWaitingTransitions`/`onWaitingEntered`/`makeWaitingNotification`/`badgeText`/`isWaitingHighlight` untouched by Phase 2; TmuxWaitingPolicyTests all 12 PASSED; `test_DW_2_1_badge*` and `test_DW_2_2_highlight*` PASSED | PASS |

## Test-DW Coverage
- [x] All DW items have execution evidence ran in Step 0.
- [x] DW-2.1 → `test_DW_2_1_windowDecodesActivityWhenPresent`, `test_DW_2_1_windowActivityDefaultsToZeroWhenAbsent` (DW-traceable by name).
- [x] DW-2.2 → `test_DW_2_2_relativeAgeFormatsBuckets`, `test_DW_2_2_relativeAgeBoundariesAndNegative` (DW-traceable by name).
- [x] DW-2.3 → covered via the unit-tested pure helper (`relativeAge` nil contract + `isWaitingHighlight`) plus code walk of the additive layout; no view-render harness exists (non-automatable here), so observed-behavior fallback applies correctly.
- [x] DW-2.4 → the suite run itself (104/104).
- [x] DW-2.5 → doc verified by direct read (non-code item).
- [x] Coverage level "Targeted (3–5 tests)": exactly 4 new Phase-2 tests added (2 decode + 2 relativeAge), within the project's 3–5 cap.

## Dead Code
None found. New code (`activity` field, `relativeAge`, the `if let age` view block) is all reachable and used. No unused imports, no unreachable-after-return, no debug prints, no commented-out blocks introduced.

## Correctness Dimensions
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | N/A | `relativeAge` is pure/static; `now` is injected. View reads `Date()` on the main-actor render path. No new shared mutable state introduced. |
| Error Handling | PASS | `activity` is external (AI-written file). Barricade is correct: `decodeIfPresent ?? 0` normalizes absent → sentinel 0; `relativeAge` maps 0→nil ("unknown"). Negative diff handled (not asserted) → "now". Matches the cc-defensive-programming barricade pattern: validate external input at the decode boundary, no side-effecting assertions, no empty catch. |
| Resources | N/A | No file handles, connections, locks, or threads added by this phase. |
| Boundaries | PASS | Bucket thresholds verified at exact edges (59/60, 3599/3600, 86399/86400) and at 0 and negative by `test_DW_2_2_relativeAgeBoundariesAndNegative` (PASSED). Integer division floors correctly. No overflow risk demonstrable for realistic epoch ints. |
| Security | PASS | Untrusted external input (status file) decoded leniently and never used to drive control flow beyond display; activity is an Int and cannot inject. Summary still capped at `maxSummaryLength` (View:237). No new injection surface. |

## Notes (non-blocking)
- DW-2.3's age block calls `relativeAge(..., now: Date())` per render. This re-reads the wall clock on each SwiftUI body evaluation; the displayed age can therefore drift between renders without a data change. This is intended ("muted relative age") and matches the existing `statusText`/`RelativeDateTimeFormatter` pattern in the same file — design note only, not a defect.
- The age `Text` shares the name HStack and sits after `Spacer()`; with a very long window name (`lineLimit(1)` truncates) the age stays visible because the name truncates first. Layout is sound; no requirement on long-name behavior, so this is informational.

## Issues (if FAIL)
None.

**Verdict: PASS**
