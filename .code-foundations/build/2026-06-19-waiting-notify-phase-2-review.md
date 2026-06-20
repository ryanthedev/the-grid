# Review: Phase 2 - Waiting-notify dashboard indicator

## Executed Results (Step 0)
- Test suite: `cd grid-notify && swift build && swift test` → 100 tests, 0 failures (0 unexpected). TmuxDashboardTests: 22 tests, all pass.
- Build: `swift build` → BUILD_EXIT=0, "Build complete!" (no warnings).
- Typecheck: covered by `swift build` (Swift compiles types as part of build) → clean.
- Lint: no separate linter configured for this package; build is warning-free.

## Requirement Fulfillment

### DW-2.1
PREMISE:  With ≥1 waiting window the header renders a `N need input` badge equal to `waitingCount`; with 0 the badge is absent.
EVIDENCE:
- Helper: TmuxDashboardViewModel.swift:134-137 `badgeText(waitingCount:)` → `guard waitingCount > 0 else { return nil }; return "\(waitingCount) need input"`.
- Source: TmuxDashboardViewModel.swift:109-113 `waitingCount` reduces over `@Published sessions`, counting `statusKind == .waiting`.
- View binding: TmuxDashboardView.swift:71-79 — header does `if let badge = TmuxDashboardViewModel.badgeText(waitingCount: viewModel.waitingCount) { Text(badge)... }`. The `if let` means at 0 (nil) no `Text` is emitted → badge absent.
TRACE:  canonicalJSON (1 waiting window) → `waitingCount == 1` → `badgeText(1) == "1 need input"` → `if let` succeeds → badge `Text` rendered. Zero-waiting JSON → `waitingCount == 0` → `badgeText(0) == nil` → `if let` fails → no badge.
Tests run in Step 0: `test_DW_2_1_badgeTextShowsCountWhenWaiting`, `test_DW_2_1_badgeTextNilWhenZeroWaiting`, `test_DW_2_1_waitingCountDrivesBadgeText`, `test_DW_2_1_badgeAbsentWhenNoWaiting`, `test_DW_2_1_badgeCountsAllWaitingWindows` — all passed.
VERDICT: PASS

### DW-2.2
PREMISE:  A `.waiting` window row renders the highlight (tint/accent) in addition to the glyph; non-`.waiting` rows render without it.
EVIDENCE:
- Predicate: TmuxDashboardViewModel.swift:142-144 `isWaitingHighlight(_:)` → `window.statusKind == .waiting`.
- View binding: TmuxDashboardView.swift:221-223 `isWaiting = TmuxDashboardViewModel.isWaitingHighlight(window)`; lines 226-230 `rowBackground` returns waiting tint (`Color(TmuxStatusKind.waiting.color).opacity(0.12)`) only when `isWaiting` (and selection wins when both); lines 281-287 left accent `Rectangle` overlay drawn only `if isWaiting`. The glyph (lines 247-250) is always rendered, so highlight is *in addition to* the glyph.
TRACE:  window.statusKind == .waiting → `isWaiting == true` → `rowBackground` = yellow tint AND accent bar overlay drawn. statusKind == active/running/idle/error → `isWaiting == false` → `rowBackground` = `.clear`, no overlay → renders as before (glyph still present).
Tests run in Step 0: `test_DW_2_2_highlightPredicateTrueOnlyForWaiting`, `test_DW_2_2_highlightPredicateFalseForNonWaitingKinds` — all passed.
VERDICT: PASS

**All requirements met:** YES

## Edge Cases
| Edge case | Handling | Evidence |
|-----------|----------|----------|
| `waitingCount == 0` → no badge; zero-state and normal rows unaffected | PASS | `badgeText(0) == nil` (VM:135) → `if let` skips Text (View:71). Zero-state view (View:44-45) is separate from header; rows use `isWaiting==false` → clear bg. `test_DW_2_1_badgeAbsentWhenNoWaiting` passed. |
| Many waiting windows → badge shows count; rows still scroll | PASS | `waitingCount` sums across all sessions/windows (VM:109-113); badge = `"3 need input"`. Rows live inside `ScrollView`/`LazyVStack` (View:113-114) so scrolling is unaffected. `test_DW_2_1_badgeCountsAllWaitingWindows` (3 windows) passed. |
| Non-waiting rows render exactly as today (no highlight regression) | PASS | `rowBackground` returns `.clear` and overlay skipped when `!isWaiting` (View:226-230, 282); selection path unchanged. `test_DW_2_2_highlightPredicateFalseForNonWaitingKinds` covers active/running/idle/error. |

## Test-DW Coverage
- [x] All DW items have corresponding tests that ran in Step 0 (DW-2.1: 5 tests; DW-2.2: 2 tests).
- [x] Coverage matches stated level: value sources (`waitingCount`) + pure helpers (`badgeText`, `isWaitingHighlight`) are unit-tested; the view bindings were verified by code inspection (badge bound via `if let badgeText(waitingCount:)`, highlight bound via `isWaitingHighlight`). Visual GUI render is the documented manual check, not required.
- No gaps.

## Dead Code
None found in the reviewed files. All imports used (SwiftUI in View; AppKit/Foundation in ViewModel — AppKit needed for `NSFont`/`NSColor` via `Color(TmuxStatusKind.waiting.color)` and theme). No unreachable code after returns; no debug prints; no commented-out blocks.

## Correctness Dimensions
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | ViewModel is `@MainActor`; `waitingCount` is a synchronous computed property over `@Published sessions` read on the main actor from SwiftUI. No shared mutable cross-actor state introduced by Phase 2. |
| Error Handling | N/A | Phase 2 adds two pure, total functions (`badgeText`, `isWaitingHighlight`) and view bindings — no I/O, parsing, or external calls. |
| Resources | N/A | No file handles, connections, locks, or threads opened by Phase 2 code. |
| Boundaries | PASS | `badgeText` guards `waitingCount > 0` (also handles negative → nil, tested). `waitingCount` over empty sessions = 0 (reduce base). `displaySummary` caps via `prefix(maxSummaryLength)`. No out-of-range access. |
| Security | N/A | No untrusted input handled in Phase 2 surface (badge/highlight derive from already-decoded model). |

## Notes (non-blocking)
- `badgeText`/`isWaitingHighlight` are pure static helpers with functional cohesion (one operation each), ≤1 parameter — clears cc-routine-and-class-design parameter and cohesion checks. No inheritance introduced (View structs conform to SwiftUI `View` protocol — framework-mandated). No LSP/containment concerns.
- Badge color uses `Color(TmuxStatusKind.waiting.color)` and row tint uses the same at 0.12 opacity, keeping the badge, accent bar, and glyph visually consistent with the waiting kind. Verified `TmuxStatusKind.waiting` and `.color` exist (TmuxStatusModel.swift:12, 28).
- Selection precedence is intentional: when a row is both selected and waiting, `rowBackground` returns `surfaceSelected` (selection wins) but the left accent bar overlay still renders, so the waiting signal is not lost. Consistent with DW-2.2 ("highlight in addition to the glyph").

**Verdict: PASS** — both DW items satisfied with execution evidence; all three listed edge cases handled; no correctness defects, no blocking dead code.
