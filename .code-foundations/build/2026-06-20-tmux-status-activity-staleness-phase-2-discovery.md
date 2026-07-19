# Discovery + Design: Phase 2 - Swift consumer + age display (+ doc)

## Files Found
- `grid-notify/Sources/GridNotify/TmuxStatusModel.swift` — `TmuxStatusKind`, `TmuxWindow` (Decodable, explicit memberwise init + synthesized `init(from:)`), `TmuxSession` (custom `init(from:)` with `decodeIfPresent(activity) ?? 0`), `TmuxStatusData`.
- `grid-notify/Sources/GridNotify/TmuxDashboardViewModel.swift` — `@MainActor` view model. Existing pure statics: `makeWaitingNotification`, `badgeText`, `isWaitingHighlight`. The home for `relativeAge`.
- `grid-notify/Sources/GridNotify/TmuxDashboardView.swift` — `TmuxDashboardWindowRow` renders glyph + name HStack (name / `*` active marker / `Spacer()`) + summary, with selection/waiting backgrounds.
- `docs/TMUX_DASHBOARD.md` — user-facing dashboard doc with a "Status File Schema" JSON block + `statusKind` enumeration.
- `grid-notify/Tests/GridNotifyTests/TmuxStatusTests.swift` — decode tests (has `decode(_:)` helper + an existing `activity` decode-when-present/default-when-absent pattern at session level, lines 115-135). Natural home for DW-2.1 window decode tests.
- `grid-notify/Tests/GridNotifyTests/TmuxDashboardTests.swift` — `TmuxDashboardViewModel` static-helper tests (`badgeText`, `isWaitingHighlight`). Natural home for DW-2.2 `relativeAge` tests.
- `grid-notify/Tests/GridNotifyTests/TmuxWaitingPolicyTests.swift` — builds `TmuxWindow(...)` via memberwise init (helper `window(...)`, lines 14-26) and defines `extension TmuxWindow: Encodable` with its own `private enum CodingKeys` (lines 245-260, no `activity`).

## Current State
- `TmuxWindow` is `Decodable` with seven fields (no `activity`). It relies on the **synthesized** `Decodable.init(from:)` for the file-loading path AND has an explicit memberwise init used by tests.
- `TmuxSession` already demonstrates exactly the back-compat pattern Phase 2 needs for `TmuxWindow`: a custom `init(from:)` with explicit `CodingKeys` and `decodeIfPresent(Int.self, forKey: .activity) ?? 0`.
- Baseline `swift build` is clean; `swift test` = 100 tests, 0 failures (captured pre-change).

## Gaps
| # | Gap | Resolution |
|---|-----|-----------|
| 1 | `TmuxWindow` has no `activity` field and no custom `init(from:)`. | Add `let activity: Int`, explicit `CodingKeys`, custom `init(from:)` with `decodeIfPresent ?? 0` (mirrors `TmuxSession`). |
| 2 | Memberwise init has no `activity` param → adding a non-defaulted one breaks every existing call site (`TmuxWaitingPolicyTests`, `TmuxDashboardTests`). | Give the param a DEFAULT: `activity: Int = 0`. Existing call sites compile unchanged. |
| 3 | No relative-age formatter exists. | Add pure static `relativeAge(activity:now:) -> String?` to `TmuxDashboardViewModel`. |
| 4 | `TmuxDashboardWindowRow` shows no age. | Add a muted, right-aligned age label after the existing `Spacer()` in the name HStack. |
| 5 | `docs/TMUX_DASHBOARD.md` schema omits `activity` + staleness rule. | Add `activity` to the JSON sample + a prose note on the >300s staleness→idle behavior. |

**Encoder CodingKeys coexistence:** the test file's `extension TmuxWindow: Encodable { private enum CodingKeys ... }` and the model's new struct-nested `private enum CodingKeys` live in separate scopes and are each `private`/file-local, so they do not collide. The test encoder will simply not emit `activity` (round-trips to 0) — harmless, since no waiting-policy test asserts `activity`. `swift build` is the source of truth and will confirm.

## Code Standards
From `docs/code-standards.md`:
- Comments on their own line above code, never inline trailing (§1).
- `test_DW_<phase>_<item>_<descriptor>` naming for done-when-tied tests; block comment above each (§5).
- Pure-logic tests preferred — extract decision predicates as `static` helpers (§5). `relativeAge` fits this exactly.
- 3–5 targeted tests per feature (§5 / project CLAUDE.md). The dispatch caps at 3–5; I will keep the new DW tests within that.
- No `print()` (§1) — N/A here (pure formatting, no logging added).

## Test Infrastructure
- XCTest. Run from `grid-notify/` via `swift build` / `swift test`.
- `TmuxStatusTests` has `decode(_:)` → `TmuxStatusData`; mirror its session-activity decode tests for the window field.
- `TmuxDashboardTests` is `@MainActor`; `relativeAge` is a pure static and can be asserted directly with a fixed `now`.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-2.1 | `TmuxWindow` decodes `activity` when present and defaults it to 0 when absent (back-compat). | COVERED | `test_DW_2_1_windowDecodesActivityWhenPresent`, `test_DW_2_1_windowActivityDefaultsToZeroWhenAbsent` (in TmuxStatusTests). |
| DW-2.2 | `relativeAge(activity:now:)` returns nil for 0 and correct "now"/"Nm"/"Nh"/"Nd" otherwise; negative diff → "now". | COVERED | `test_DW_2_2_relativeAgeFormatsBuckets` (nil@0, 30s→now, 300s→5m, 7200s→2h, 172800s→2d), `test_DW_2_2_relativeAgeBoundariesAndNegative` (59s→now, 60s→1m, 3599s→59m, 3600s→1h, 86399s→23h, 86400s→1d, negative→now) (in TmuxDashboardTests). |
| DW-2.3 | `TmuxDashboardWindowRow` shows age (when non-nil) without disturbing name/`*`/summary/waiting-highlight layout. | COVERED | Verified structurally: age label added after the existing `Spacer()` in the name HStack, gated on `relativeAge(...) != nil`; existing layout/highlight untouched. Behavioral proof rides on `relativeAge` tests (DW-2.2) that feed it + the full-suite green (DW-2.4) confirming no layout-path regression. SwiftUI view bodies are not unit-tested in this project (no existing view-render test precedent); the row's only branchable logic is the pure helper, which is covered. |
| DW-2.4 | `swift build` clean and full `grid-notify` suite stays green (no regressions). | COVERED | `swift build` + `swift test` run after implementation; baseline was 100/0 and the new tests are additive. |
| DW-2.5 | `docs/TMUX_DASHBOARD.md` documents per-window `activity` + staleness behavior. (grug half = orchestrator.) | COVERED | Doc edit: add `"activity": <int epoch>` to the schema sample + a staleness-rule note. Verified by reading back the edited section. No automated test for prose; the doc is the artifact. |

**All items COVERED:** YES (DW-ID count = 5, matches dispatch prompt.)

## Design Decisions

### `relativeAge` (cc-defensive-programming applied)
- **Barricade placement:** `activity` is external input (AI-written status file). The decode barricade (`decodeIfPresent ?? 0`) normalizes "absent/garbage-missing" to the sentinel `0`. `relativeAge` is *inside* the barricade and treats `0` as "unknown → nil" (no age shown) — the plan's explicit contract, not a bogus "56y ago".
- **Negative diff (clock skew) → "now":** robustness over correctness. The dashboard is a consumer/internal tool; a skewed clock should never surface a negative or wrapped age. Clamp by treating `seconds < 60` (which includes all negatives) as "now". This is a single guard, not an assertion — clock skew is an *anticipated runtime condition*, not a programmer bug, so it gets handling, not `assert`.
- **No executable code in assertions / no empty catch:** the helper is pure arithmetic + string formatting; no `assert`, no `catch`, no I/O. Nothing to compile out.
- **Signature:** `static func relativeAge(activity: Int, now: Date) -> String?` — `now` injected (not `Date()`) so the buckets are deterministically testable, mirroring how the existing statics take their inputs.
- **Buckets (from plan):** `activity == 0` → nil; else `seconds = Int(now.timeIntervalSince1970) - activity`; `< 60` (incl. negative) → "now"; `< 3600` → "\(seconds/60)m"; `< 86400` → "\(seconds/3600)h"; else "\(seconds/86400)d".

### `TmuxWindow.activity` (back-compat decode)
- Mirror `TmuxSession`: explicit `private enum CodingKeys`, custom `init(from:)` using `decode` for the seven required fields and `decodeIfPresent(Int.self, forKey: .activity) ?? 0` for the new one. This makes the file-load path lenient (older files omit the key → 0) — exactly the barricade behavior the skill prescribes for external input. Required fields stay strict `decode` (a malformed file that drops `name`/`target` should still throw, as the existing decode tests assert).
- Memberwise init gains `activity: Int = 0` (defaulted, placed last) so all existing `TmuxWindow(...)` call sites compile unchanged.

### `TmuxDashboardWindowRow` age label
- Add the age label after the existing `Spacer()` in the name HStack (the Spacer already pushes trailing content right). `dashboardMono(size: DashTypeSize.meta)`, `viewModel.theme.textTertiary` (muted). Gate render on `if let age = TmuxDashboardViewModel.relativeAge(activity: window.activity, now: Date()) { ... }` so `activity == 0` shows nothing. Do not touch the `*` marker, summary, selection, or waiting-highlight overlay.

## Prerequisites
- [x] Required files exist.
- [x] Phase 1 JSON contract (`windows[].activity` int epoch) committed (e267dce).
- [x] Baseline suite green (100/0).
- [x] `cc-defensive-programming` skill loaded.

## Recommendation
BUILD — all five DW items are COVERED, no scope gaps, no missing prerequisites. Implement the model field (back-compat decode + defaulted memberwise param), the pure `relativeAge` helper, the row age label, and the doc update; then add the DW-2.1/DW-2.2 tests and run the full suite.
