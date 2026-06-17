# Discovery + Design: Phase 3 - Dashboard view + viewmodel + window

## Files Found

- `grid-notify/Sources/GridNotify/TmuxStatusModel.swift` — P2 model (TmuxStatusData, TmuxSession, TmuxWindow, TmuxStatusKind + glyph/color)
- `grid-notify/Sources/GridNotify/TmuxStatusWatcher.swift` — P2 watcher (start/stop/onChange)
- `grid-notify/Sources/GridNotify/NotificationPanelViewModel.swift` — mirror target for ViewModel
- `grid-notify/Sources/GridNotify/NotificationPanelWindow.swift` — mirror target for Window
- `grid-notify/Sources/GridNotify/NotificationPanelViews.swift` — mirror target for Views
- `grid-notify/Sources/GridNotify/DetailWindow.swift` — pop-out controller (openDetail/dismissDetail)
- `grid-notify/Sources/GridNotify/DetailViewModel.swift` — pop-out viewmodel (loadDetail + DetailState)
- `grid-notify/Sources/GridNotify/DetailViews.swift` — pop-out SwiftUI views
- `grid-notify/Sources/GridNotify/NotificationPanelTheme.swift` — theme (reuse as-is)
- `grid-notify/Tests/GridNotifyTests/TmuxStatusTests.swift` — 15 existing P2 tests (baseline)

## Current State

Three new files need to be created (none exist yet):
- `TmuxDashboardViewModel.swift`
- `TmuxDashboardView.swift`
- `TmuxDashboardWindow.swift`

Test file `TmuxDashboardTests.swift` also needs to be created.

## Gaps

None. All prerequisites (model, watcher, DetailWindowController, theme) are fully implemented and tested. The existing DetailWindowController.openDetail(command:title:theme:) API is exactly what DW-3.4 needs — `tmux capture-pane -pt <target> -S -200` is the command string.

## Code Standards

Key conventions from docs/code-standards.md that apply:
- `jlog(...)` only — never `print()` (§1)
- No inline trailing comments; all comments on own line above (§1, CLAUDE.md)
- `[weak self]` + `guard let self else { return }` in all escaping closures (§1)
- Per-module `Error, LocalizedError` enum (§3) — not needed for this phase (no throws)
- `PascalCase.swift` per primary type (§6)
- Pure decision predicates as static helpers for testability (§7)
- SwiftUI is correct in grid-notify; the actors-only/no-SwiftUI rule is grid-server-scoped (§8, plan notes)
- `@MainActor` + `@Published` mirrors NotificationPanelViewModel exactly
- `isReleasedWhenClosed = false`, `setFrameAutosaveName` mirrors NotificationPanelWindow

## Test Infrastructure

- XCTest, `@testable import GridNotify`
- Test file: `grid-notify/Tests/GridNotifyTests/`
- Test naming: `test_DW_<phase>_<item>_<descriptor>`
- 3–5 targeted tests per feature (CLAUDE.md)
- SwiftUI view behavior tested through ViewModel state (view cannot be unit-tested headlessly on macOS without an App context)
- DW-3.4 (Enter key opens detail) is a manual-only check — it requires a live NSWindow + keyDown dispatch; the ViewModel's `openDetailCommand(for:)` pure helper IS testable

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|----------------|--------|------------|
| DW-3.1 | `load(_:)` populates `@Published sessions`/`generatedAt`; SwiftUI tree renders sessions with statusKind glyph + summary | COVERED | `test_DW_3_1_loadPopulatesSessions`, `test_DW_3_1_generatedAtConvertedToDate`, `test_DW_3_1_multipleSessionsAndWindows` |
| DW-3.2 | Empty `TmuxStatusData` renders zero-state | COVERED | `test_DW_3_2_emptyDataYieldsEmptySessions`, `test_DW_3_2_emptySessionsIsZeroState` |
| DW-3.3 | Refresh button invokes `onRefreshRequested` | COVERED | `test_DW_3_3_refreshCallsOnRefreshRequested` |
| DW-3.4 | Enter on window row opens detail pop-out | COVERED (manual for window) | `test_DW_3_4_openDetailCommandForWindow` — tests the pure helper that produces the capture-pane command; manual check for NSWindow key dispatch |

**All items COVERED:** YES (DW-3.4 is covered by a unit test of the pure helper; the NSWindow keyDown-to-openDetail path is noted as manual-check only)

## Design: TmuxDashboardViewModel

### Approaches Considered

1. **Thin mapper** — ViewModel directly exposes `TmuxStatusData` model types (`[TmuxSession]`, raw `Date`). Caller accesses `session.windows[i].statusKind.glyph` directly in the view. The ViewModel's sole job is `load(_:)` → convert `generatedAt: Int` → `Date`, call `onRefreshRequested`.

2. **View-model projection** — ViewModel creates separate `DashboardSessionRow` / `DashboardWindowRow` value types tailored to the view (precomputed display strings, collapsed state, selection index). The view never touches model types.

3. **Hybrid** — ViewModel publishes `[TmuxSession]` directly (no projection types), but owns collapsedSessions state and exposes the pure helper `openDetailCommand(for: TmuxWindow) -> String` so the view calls it on Enter.

### Comparison

| Criterion | A: Thin mapper | B: View projection | C: Hybrid |
|-----------|---------------|-------------------|-----------|
| Interface simplicity | High — one method, two properties | Low — many row types, many properties | High — reuses existing model types |
| Information hiding | Medium — view knows model types | High — view knows only row types | Medium — same as A |
| Caller ease of use | High — view uses model directly | Low — must convert or use projections | High — model types already have glyph/color |
| Testability | High — load() easy to test | High — row state easy to test | High — pure helper is unit-testable |
| Scope fit | Fits perfectly | Over-engineers for this phase | Best fit |

### Choice: A (Thin mapper, close to C)

Rationale: `TmuxSession` and `TmuxWindow` are already well-shaped value types from P2 with `glyph`, `color`, `summary`, `target` computed. Creating projection types would be classitis — small wrappers that hide what the view legitimately needs. The view accesses `statusKind.glyph` which is `TmuxWindow`'s API surface, not internal detail. The ViewModel adds exactly what it needs to: `Date` conversion, collapsed-state for sessions, `onRefreshRequested`, and a pure `openDetailCommand(for:)` helper.

### Depth Check
- Interface methods/properties: `load(_:)`, `@Published sessions`, `@Published generatedAt`, `@Published collapsedSessions`, `onRefreshRequested`, `toggleCollapsed(_:)`, `openDetailCommand(for:)`
- Hidden details: `generatedAt: Int` → `Date` conversion, collapsedSessions Set management
- Common case complexity: simple — call `load(_:)` to update; bind `sessions` in view

## Design: TmuxDashboardView

The view mirrors NotificationPanelViews.swift structure:
- `TmuxDashboardContentView` — top-level VStack (header + session list OR empty state + status bar)
- `TmuxDashboardHeaderView` — title "Tmux Sessions" + Refresh button
- `TmuxDashboardSessionRow` — collapsible session (name + attached badge + disclosure triangle)
- `TmuxDashboardWindowRow` — glyph + name + summary (truncated), Enter key → openDetail
- `TmuxDashboardEmptyView` — zero-state ("No tmux sessions")

## Design: TmuxDashboardWindow

Mirrors NotificationPanelWindow exactly:
- `.titled | .closable | .resizable | .fullSizeContentView` style mask
- `isReleasedWhenClosed = false`
- `setFrameAutosaveName("TmuxDashboard")`
- `NSHostingView<TmuxDashboardContentView>` as contentView
- `keyDown` intercepts Return (keyCode 36) to open detail for selected window
- `canBecomeKey = true`

## Prerequisites

- [x] TmuxStatusModel.swift (P2 — TmuxStatusData, TmuxSession, TmuxWindow, TmuxStatusKind)
- [x] DetailWindowController.shared.openDetail(command:title:theme:) — exists in DetailWindow.swift
- [x] NotificationPanelTheme.default — exists and reusable
- [x] XCTest infrastructure — 35 tests pass

## Recommendation

BUILD — All prerequisites met, design is clear, implementation path is obvious.
