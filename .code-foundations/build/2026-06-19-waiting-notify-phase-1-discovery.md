# Discovery + Design: Phase 1 - Transition/dedupe predicate + notification emission

## Files Found
- `grid-notify/Sources/GridNotify/TmuxStatusModel.swift` — `TmuxStatusKind` (incl. `.waiting`), `TmuxWindow` (`.target`, `.statusKind`, `.summary`), `TmuxSession`, `TmuxStatusData`. All `Decodable` only; `TmuxWindow` has NO memberwise init exposed.
- `grid-notify/Sources/GridNotify/TmuxDashboardViewModel.swift` — `@MainActor` `ObservableObject`; `@Published var sessions`, `load(_:)` (the single funnel), `loadGeneration`, `onRefreshRequested`.
- `grid-notify/Sources/GridNotify/AppDelegate.swift` — `setupTmuxDashboard(...)` (~L158); `watcher.onChange → Task { @MainActor in vm?.load(data) }`; `private var store: NotificationStore?` created at L47.
- `grid-notify/Sources/GridNotify/NotificationStore.swift` — actor; `add(_:)` (idempotent by id), `upsert(_:)`.
- `grid-notify/Sources/GridNotify/Notification.swift` — `GridNotification` init (id default UUID, source, title, body, detailCmd, priority, ttl, action…).
- `grid-notify/Tests/GridNotifyTests/TmuxDashboardTests.swift` — `@MainActor final class`, decode-from-JSON helpers, `test_DW_*` names.

## Current State
- `load(_:)` sorts + publishes sessions, sets `generatedAt`, bumps `loadGeneration`, jlogs. No waiting detection, no `waitingCount`, no notifier closure.
- `setupTmuxDashboard` wires watcher→`vm.load`, refresh button→driver. `store` is reachable on the AppDelegate as `self.store`. No waiting→notification wiring.
- Tests build `TmuxWindow`/`TmuxStatusData` exclusively via `JSONDecoder`.

## Gaps
- `TmuxWaitingPolicy.swift` does not exist (new file).
- `TmuxWindow` has no memberwise init → policy unit tests would be forced through JSON. Add an internal memberwise init (additive, non-breaking — does not suppress `Decodable`'s synthesized init since no custom init exists yet; explicit init + existing `Decodable` coexist).
- viewModel lacks `previousWaiting`, baseline flag, `waitingCount`, `onWaitingEntered`, and the policy call in `load(_:)`.
- AppDelegate lacks the notifier→GridNotification→`store.add` wiring.

## Code Standards
- `docs/code-standards.md` FOUND. Applies: pure `enum *Policy { static func }` returning NAMED result (§7, OP-1) with co-located `*PolicyTests.swift`; `jlog` not `print`; comments on own line, never trailing; `[weak self]` + `guard let self else { return }` in escaping closures; `NotificationStore` is an actor (post via `Task`); `test_DW_<phase>_<item>_<descriptor>`. §8 "no SwiftUI" is grid-server-scoped — does NOT apply to grid-notify (confirmed in plan L48).

## Test Infrastructure
- XCTest; `@testable import GridNotify`; `swift test` from `grid-notify/`. Decode-from-JSON helpers for tmux models; `test_DW_*` naming. Will add memberwise init so `TmuxWaitingPolicyTests` build windows directly.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-1.1 | `diff` returns `newlyWaiting` = `.waiting` targets absent from `previousWaiting`; `waitingNow` = all `.waiting` targets | COVERED | `test_DW_1_1_diff_newlyWaiting_and_waitingNow` |
| DW-1.2 | Target waiting on two consecutive diffs → in `newlyWaiting` only first time | COVERED | `test_DW_1_2_dedupe_stays_waiting_not_repeated` |
| DW-1.3 | Target leaves then re-enters `waiting` → in `newlyWaiting` again | COVERED | `test_DW_1_3_rearm_after_leaving_waiting` |
| DW-1.4 | viewModel does NOT invoke `onWaitingEntered` on first `load` even if already `.waiting`; DOES on later transition | COVERED | `test_DW_1_4_baseline_seed_no_emit_then_emit_on_transition` |
| DW-1.5 | Real transition invokes `onWaitingEntered` once per window; emission helper builds `GridNotification` title `"<target> needs input"`, body=`summary`, detailCmd=`tmux capture-pane -pt <target> -S -200` | COVERED | `test_DW_1_5_onWaitingEntered_once_per_window`, `test_DW_1_5_emission_helper_builds_notification` |
| DW-1.5b | AppDelegate wiring posts the `GridNotification` to `NotificationStore` (integration/reasoned; compiles) | COVERED | `test_DW_1_5b_store_add_persists_built_notification` (drives the same helper→`store.add` path the wiring uses) + build/compile of the wiring |
| DW-1.6 | `viewModel.waitingCount` == number of `.waiting` windows after `load` | COVERED | `test_DW_1_6_waitingCount_matches_waiting_windows`, `test_DW_1_6_empty_data_zero_count` |

**All items COVERED:** YES (7 DW-IDs in prompt, 7 here)

Additional (beyond floor): re-arm when window disappears (edge), multiple windows enter in one load (edge), unique-id-per-episode prevents `add` idempotency from dropping a re-entry post.

## Design Decisions
Chosen (Approach A — the plan contract):
- `enum TmuxWaitingPolicy { static func diff(previousWaiting: Set<String>, windows: [TmuxWindow]) -> TmuxWaitingDiff }`; `struct TmuxWaitingDiff: Equatable { let newlyWaiting: [TmuxWindow]; let waitingNow: Set<String> }`. Pure: `waitingNow` = targets where `statusKind == .waiting`; `newlyWaiting` = those waiting windows whose target ∉ `previousWaiting`. Disappearance handled implicitly — absent targets simply not in `waitingNow`, re-arming them.
- viewModel: stored `private var previousWaiting: Set<String> = []`, `private var didBaseline = false`; `var onWaitingEntered: (([TmuxWindow]) -> Void)?`; computed `var waitingCount: Int` derived from `@Published sessions` (reactive, no extra `@Published`). In `load(_:)`: compute diff over all windows; first call seeds `previousWaiting` + sets `didBaseline` WITHOUT invoking the closure; later calls invoke closure with `newlyWaiting` if non-empty; always update `previousWaiting = waitingNow`.
- Pure emission helper (static, testable off the actor): `static func makeNotification(for window: TmuxWindow) -> GridNotification` → title `"\(target) needs input"`, body `summary`, detailCmd `"tmux capture-pane -pt \(target) -S -200"`, source `"tmux"`, no action. Unique id `"tmux-waiting-\(target)-\(UUID)"` so each episode is distinct and `add` never silently dedupes a re-entry.
- AppDelegate: set `vm.onWaitingEntered = { [weak self] windows in ... Task { await self.store?.add(...) } }`.

Defensive (cc-defensive-programming): external input validated at the decode barricade (lenient → `.idle`); post-barricade treated as validated (not security-critical, robustness lean). Empty/missing data → empty set, no crash. No empty catch. `Task` post uses `[weak self]` + `guard let self`.

## Prerequisites
- [x] Required files exist (TmuxWaitingPolicy.swift to be created)
- [x] Dependencies available (models, store, notification all present)
- [x] No missing prerequisites

## Recommendation
BUILD — create `TmuxWaitingPolicy.swift` + emission helper, extend `TmuxWindow` with memberwise init, extend the viewModel with the transition seam, wire AppDelegate, add `TmuxWaitingPolicyTests.swift`.
