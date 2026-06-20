# Discovery + Design: Phase 2 - Dashboard "needs input" indicator

## Files Found
- `grid-notify/Sources/GridNotify/TmuxDashboardView.swift` — SwiftUI tree: `TmuxDashboardHeaderView` (title + Refresh button, L59-87) and `TmuxDashboardWindowRow` (glyph + name + summary, L195-260). Styling tokens `DashSpace`, `DashTypeSize`, `dashboardMono` defined at top (L6-31).
- `grid-notify/Sources/GridNotify/TmuxDashboardViewModel.swift` — `waitingCount` computed property already exists (L109-113), derived over `@Published var sessions` (reactive). `makeWaitingNotification` static helper exists from Phase 1.
- `grid-notify/Sources/GridNotify/TmuxStatusModel.swift` — `TmuxStatusKind.waiting` has `.color` = `NSColor.systemYellow` (L33) and `.glyph` = "⏸" (L21). `TmuxWindow.statusKind` is the row's classification.
- `grid-notify/Tests/GridNotifyTests/TmuxDashboardTests.swift` — `@MainActor final class TmuxDashboardTests: XCTestCase`, `decode(_:)` helper, `canonicalJSON` sample (work session active/running + claude-mux session waiting). `test_DW_<phase>_<item>_<descriptor>` naming used throughout.

## Current State
- Header (`TmuxDashboardHeaderView`) shows title "Tmux Sessions" + Refresh button. No badge.
- Window rows (`TmuxDashboardWindowRow`) render the statusKind glyph in `.color` plus name + summary. Selected rows get `theme.surfaceSelected` background; others `Color.clear`. No waiting-specific highlight.
- `waitingCount` (computed) already correct and reactive — Phase 1 produced it. Phase 2 only consumes it.

## Gaps
- No badge view in the header.
- No highlight (tint/accent bar) on `.waiting` rows.
- No pure helpers for badge text or row-highlight predicate (plan permits adding tiny ones if they read naturally — they make DW-2.1/DW-2.2 unit-testable off the SwiftUI boundary).

## Code Standards
`docs/code-standards.md` present and applied:
- §1 no `print` (use `jlog`); no inline trailing comments (comments on own line above code). The badge/highlight additions are pure presentation — no logging needed.
- §5 test names `test_DW_<phase>_<item>_<descriptor>`; pure-logic predicates preferred (extract `static` helpers), test off the boundary.
- §6 `PascalCase.swift` matching primary type.
- §8 "No SwiftUI" is grid-server-scoped — grid-notify IS the SwiftUI side, so SwiftUI here is correct (confirmed by existing `TmuxDashboardView.swift`).

## Test Infrastructure
XCTest, `@testable import GridNotify`, `@MainActor` test class. Baseline: 93 tests pass, clean build. ViewModel constructed directly + `load(decode(json))`; assertions read `vm.sessions`/`vm.waitingCount`.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-2.1 | With ≥1 waiting window the header renders a `N need input` badge equal to `waitingCount`; with 0 the badge is absent. | COVERED | `test_DW_2_1_badgeTextShowsCountWhenWaiting` (count 1/N → "N need input"), `test_DW_2_1_badgeTextNilWhenZeroWaiting` (0 → nil), `test_DW_2_1_waitingCountDrivesBadgeText` (load canonical → waitingCount==1 → badgeText=="1 need input"), `test_DW_2_1_badgeAbsentWhenNoWaiting` (load all-non-waiting → waitingCount==0 → badgeText nil) |
| DW-2.2 | A `.waiting` window row renders the highlight (tint/accent) in addition to the glyph; non-`.waiting` rows render without it. | COVERED | `test_DW_2_2_highlightPredicateTrueOnlyForWaiting` (mix of N waiting + M non-waiting → predicate true exactly for the N), `test_DW_2_2_highlightPredicateFalseForNonWaitingKinds` (active/running/idle/error → false) |

**All items COVERED:** YES (2 DW-IDs in prompt, 2 in table)

## Design Decisions

Two tiny pure static helpers on `TmuxDashboardViewModel`, both testable off SwiftUI:

1. `static func badgeText(waitingCount: Int) -> String?`
   - Returns `nil` when `count <= 0` (badge hidden); otherwise `"\(count) need input"`.
   - One operation (format the badge label) → functional cohesion. 1 param → PASS.
   - View binds: `if let badge = TmuxDashboardViewModel.badgeText(waitingCount: viewModel.waitingCount) { ... }`. Reactive because `waitingCount` reads `@Published sessions`.

2. `static func isWaitingHighlight(_ window: TmuxWindow) -> Bool`
   - Returns `window.statusKind == .waiting`. Trivially checkable, single operation, 1 param → PASS.
   - Keeps the row-highlight decision in one named, unit-testable place instead of inline `==` scattered in the view.

cc-routine-and-class-design checks:
- Cohesion: both helpers are functional (one operation each). PASS.
- Parameters: 1 each. PASS.
- Inheritance/LSP: N/A — static funcs on an existing class, no new type hierarchy. Containment-by-default respected (no inheritance introduced).

View changes (presentation only, manual visual check):
- `TmuxDashboardHeaderView`: between title and Spacer, conditionally render a badge capsule using `badgeText`. Reuse `dashboardMono`, `DashTypeSize.meta`, `DashSpace`, and `Color(TmuxStatusKind.waiting.color)` (systemYellow) for the badge fill so it matches the waiting color language.
- `TmuxDashboardWindowRow`: when `isWaitingHighlight(window)` is true, add a subtle yellow background tint (`Color(TmuxStatusKind.waiting.color).opacity(low)`) plus a left accent bar (full `.waiting.color`). Tint must keep text readable; selected-row background still applies. Non-waiting rows unchanged (no regression).

Why static helpers (not inline only): plan explicitly allows a `badgeText` helper + highlight predicate so the DW items are unit-testable without a snapshot dependency (none introduced). The SwiftUI rendering itself remains a manual visual check per the plan.

## Prerequisites
- [x] `waitingCount` exists (Phase 1, computed, reactive).
- [x] `TmuxStatusKind.waiting.color` / `.glyph` available.
- [x] Styling tokens (`DashSpace`/`DashTypeSize`/`dashboardMono`) available.
- [x] Baseline build + 93 tests green.

## Recommendation
BUILD. Add two pure static helpers (`badgeText`, `isWaitingHighlight`) to `TmuxDashboardViewModel`, wire the header badge and row highlight in `TmuxDashboardView`, and add 6 unit tests covering DW-2.1 (incl. the 0 case) and DW-2.2 (mix of waiting/non-waiting). Visual treatment verified manually.
