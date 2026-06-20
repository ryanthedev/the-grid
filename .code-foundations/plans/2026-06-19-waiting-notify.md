# Plan: tmux window enters `waiting` → notification + dashboard indicator

**Created:** 2026-06-19
**Status:** in-progress
**Started:** 2026-06-19
**Current Phase:** 2
**Complexity:** simple

---

## Context

**Problem:** theGrid's tmux dashboard (in `grid-notify`) renders each window with an
AI-assigned `statusKind`. When a window enters `waiting` it needs the user's input to unblock,
but today that state is only a small `⏸` glyph buried in an activity-sorted tree — no push
signal, easy to miss. The original dashboard plan explicitly deferred "waiting → notification".
This builds it: on the *transition* into `waiting`, post exactly one deduped notification to
grid-notify's existing notification panel, and flag waiting windows on the dashboard with more
than the glyph.

**Success criteria** (from confirmed research `2026-06-19-waiting-notify.md`):
- Entering `waiting` posts exactly ONE notification (deduped — no spam while it stays waiting;
  re-arms after it leaves `waiting`).
- The dashboard shows a clear "needs input" indicator: a header count badge + highlighted rows.
- `make verify` clean; unit tests cover the transition/dedupe predicate.

## Constraints

- **Scope:** trigger on `.waiting` ONLY (not `.error` — already red on the dashboard).
- **Notification:** title `<target> needs input`, body = window AI `summary`, **no click action**
  (the only existing focus path — `focusWindow`→grid-server — is a documented no-op in
  grid-notify standalone, and there is no tmux-target→window mapping to reuse); attach
  `detailCmd = tmux capture-pane -pt <target> -S -200` for inspection via the existing
  Enter→detail pop-out.
- **Dedupe:** key on window `target` (`session:index`); one notification per *waiting episode*;
  re-arm only when the window **leaves** `waiting`. No re-notify on summary churn.
- **First load = baseline:** seed the waiting-set without notifying, so a restart doesn't dump a
  notification per already-waiting window.
- **Indicator:** header count badge + highlighted row (yellow tint / left accent, matching the
  existing `.waiting` systemYellow). **No pinned group** — it would fight the activity-based,
  newest-at-bottom sort just shipped.
- **Detection seam:** diff each `TmuxDashboardViewModel.load(_:)` (the single funnel for every
  ~60s refresh and manual refresh) against the previous load.
- **Conventions** (`docs/code-standards.md`): extract the decision predicate as a pure
  `enum *Policy { static func … }` returning a NAMED result type (not bare `Bool`), co-located
  `*PolicyTests.swift`; `jlog` events (no `print`, no inline comments); `[weak self]` +
  `guard let self`; `test_DW_<phase>_<item>_<descriptor>` test names. grid-notify is the
  SwiftUI side — §8 "no SwiftUI" is grid-server-scoped and does not apply here. The
  `NotificationStore` is an actor (post via `Task`).

---

## Implementation Phases

### Phase 1: Transition/dedupe predicate + notification emission
**Skills:** aposd-designing-deep-modules, cc-defensive-programming
**Gate:** Full

**Goal:** Detect the edge into `waiting` by diffing each load, dedupe per `target` with re-arm,
and post exactly one notification per waiting episode into the existing `NotificationStore`.

**Scope:**
- IN:
  - New pure module `TmuxWaitingPolicy.swift` — `static func diff(previousWaiting:windows:)`
    returning a named result describing newly-entered targets and the current waiting set.
  - `TmuxDashboardViewModel` tracks the prior waiting-set + a baseline flag, calls the policy
    inside `load(_:)`, exposes `waitingCount`, and surfaces newly-entered windows via an
    injectable notifier closure (so emission is testable off the store/AppKit boundary).
  - AppDelegate `setupTmuxDashboard` wires the notifier → build `GridNotification`(s) → post to
    `NotificationStore` (via `Task`, `[weak]` captures).
- OUT: the dashboard view indicator (Phase 2); `.error`/other triggers; click-to-focus action;
  re-notify on summary change; the status-file producer skill.

**Edge cases:**
- First load with windows already waiting → baseline seed, **no** notification.
- Window stays waiting across N loads → notified once (loads 2..N yield empty newly-entered).
- Window leaves `waiting` then re-enters → re-armed, notified again.
- Window/session disappears while waiting → drops from the set (re-arms), no crash.
- Multiple windows enter `waiting` in one load → one notification each.
- Empty `TmuxStatusData` → empty waiting set, no emission, no crash.

**Produces:**
- `enum TmuxWaitingPolicy { static func diff(previousWaiting: Set<String>, windows: [TmuxWindow])
  -> TmuxWaitingDiff }` where `struct TmuxWaitingDiff { let newlyWaiting: [TmuxWindow]; let
  waitingNow: Set<String> }` (newly-entered = waiting now AND not in `previousWaiting`).
- `TmuxDashboardViewModel`: `var waitingCount: Int` — a **computed** property derived from the
  already-`@Published sessions` (so SwiftUI re-renders the badge reactively when `sessions`
  changes; no separate `@Published` needed) — and `var onWaitingEntered: (([TmuxWindow]) -> Void)?`
  invoked from `load(_:)` for non-baseline transitions. Phase 2 consumes `waitingCount`.

**Done when:**
- [ ] DW-1.1: `TmuxWaitingPolicy.diff` returns `newlyWaiting` = `.waiting` targets absent from
      `previousWaiting`, and `waitingNow` = all currently-`.waiting` targets.
- [ ] DW-1.2: A target waiting on two consecutive diffs appears in `newlyWaiting` only the first
      time (dedupe — no repeat while it stays waiting).
- [ ] DW-1.3: A target that leaves `waiting` and later re-enters appears in `newlyWaiting` again
      (re-arm).
- [ ] DW-1.4: The viewModel does NOT invoke `onWaitingEntered` on the first `load(_:)` even when
      windows are already `.waiting` (baseline seed); it DOES on a subsequent transition.
- [ ] DW-1.5: On a real transition the viewModel invokes `onWaitingEntered` exactly once per
      entered window, and the emission helper builds a `GridNotification` with title
      `"<target> needs input"`, body = `summary`, `detailCmd` =
      `tmux capture-pane -pt <target> -S -200` (unit-testable at the closure/helper seam).
- [ ] DW-1.5b: The AppDelegate wiring posts that `GridNotification` to `NotificationStore`
      (verified manually/integration during the Phase 1 run — crosses the actor/AppKit boundary).
- [ ] DW-1.6: `viewModel.waitingCount` equals the number of currently-`.waiting` windows after a
      `load(_:)`.

**Difficulty:** MEDIUM

---

### Phase 2: Dashboard "needs input" indicator
**Skills:** cc-routine-and-class-design
**Gate:** Standard

**Goal:** Surface waiting windows on the dashboard beyond the `⏸` glyph — a header count badge
and a highlighted row treatment.

**Scope:**
- IN: `TmuxDashboardView` header shows a `N need input` badge when `viewModel.waitingCount > 0`;
  `TmuxDashboardWindowRow` renders a highlight (yellow background tint + left accent bar, using
  the existing `.waiting` systemYellow color) when `window.statusKind == .waiting`.
- OUT: notification logic (Phase 1); any reordering/pinning of waiting windows.

**Edge cases:**
- `waitingCount == 0` → no badge; zero-state and normal rows unaffected.
- Many waiting windows → badge shows the count; rows still scroll.
- Non-waiting rows render exactly as today (no highlight regression).

**Produces:** (terminal phase — no downstream consumer)

**Done when:**
- [ ] DW-2.1: With ≥1 waiting window the header renders a `N need input` badge equal to
      `waitingCount`; with 0 the badge is absent.
- [ ] DW-2.2: A `.waiting` window row renders the highlight (tint/accent) in addition to the
      glyph; non-`.waiting` rows render without it.

**Difficulty:** LOW

---

## Test Coverage
**Level:** 100% of done-when items. Pure-logic seams (the diff predicate, baseline/emit gating,
`waitingCount`) get XCTest unit tests off the AppKit/actor boundary; the SwiftUI rendering
(badge/highlight) is driven by a unit-tested viewModel value (`waitingCount`) plus a manual
visual check.

## Test Plan

**Phase 1 — predicate + emission**
- [ ] Unit (clean): `diff` with one new `.waiting` window over an empty `previousWaiting` →
      `newlyWaiting` has it, `waitingNow` contains its target — DW-1.1
- [ ] Unit (dedupe): same window `.waiting` on the second diff (its target in `previousWaiting`)
      → `newlyWaiting` empty, `waitingNow` still contains it — DW-1.2
- [ ] Unit (re-arm): waiting → left (not in windows / different kind) → waiting again across
      three diffs → appears in `newlyWaiting` on entry #1 and entry #3, not in between — DW-1.3
- [ ] Unit (baseline, dirty): first `load(_:)` with an already-`.waiting` window → `onWaitingEntered`
      NOT called; a second `load(_:)` introducing a new waiting window → called with that window — DW-1.4
- [ ] Unit (emission): inject `onWaitingEntered`, trigger a transition → invoked exactly once;
      the emission helper builds a `GridNotification` with the expected title/body/detailCmd — DW-1.5
- [ ] Manual/integration: confirm the AppDelegate-wired post lands in `NotificationStore` — DW-1.5b
- [ ] Unit (boundary): empty `TmuxStatusData` → `waitingCount == 0`, no emission; populated →
      `waitingCount` matches the `.waiting` count — DW-1.6
- [ ] Dirty: a window disappears while waiting → next diff drops it from `waitingNow`
      (re-arms), no crash — Edge

**Phase 2 — indicator**
- [ ] Unit: `viewModel.waitingCount` reflects loaded data (0 → no badge condition; N → N) — DW-2.1
- [ ] Dirty: load a viewModel with N `.waiting` + M non-`.waiting` windows → `waitingCount == N`
      (badge-count source correct), and assert the row-highlight predicate
      (`window.statusKind == .waiting`) is true only for the N — DW-2.1, DW-2.2
- [ ] Manual: render with waiting windows → header badge shows the count, waiting rows show the
      tint/accent, non-waiting rows unchanged; 0 waiting → no badge — DW-2.1, DW-2.2

**Suite-level:** `make verify` (build + `swift test`) clean. Dirty:clean ratio favors the
pure predicate (dedupe/re-arm/baseline/disappear are the dirty cases), as required by the brief.

---

## Notes
- **First-load baseline** is the one subtle behavior: the viewModel suppresses emission on its
  very first `load(_:)` (seed only), so a grid-notify restart with windows already waiting does
  not spam. Locked from the research open question.
- **Why post in-process, not via the pipe / CLI relay:** the feature lives inside grid-notify
  and `load(_:)` runs on `@MainActor`; `NotificationStore` is an actor reachable directly. The
  pipe and CLI→grid-server→DistributedNotification paths are for *external* posters and would
  add needless serialization/round-trips.
- **Focus action deferred** (documented in research): the existing `focusWindow` action no-ops
  in standalone grid-notify and there's no tmux-target→window mapping; `detailCmd` preserves an
  inspect affordance at zero cost.

---

## Execution Log

### Phase 1: Transition/dedupe predicate + notification emission (Gate: Full)
- [x] BUILD: Discovery + design + implementation (stub → implement → validate) complete
- [x] REVIEW: PASS — single post-gate review; all 7 DW items + all 6 edge cases verified with executed-test evidence; 93/93 tests pass, clean build
- [x] Committed
Commit: 4914cc4
Summary: Added the waiting→notification core in grid-notify — pure `TmuxWaitingPolicy.diff` (newlyWaiting vs waitingNow), `TmuxDashboardViewModel` baseline-seeded transition detection in `load(_:)` with re-arm, `onWaitingEntered` closure, computed `waitingCount`, and the AppDelegate wiring that posts one `<target> needs input` notification per entry to `NotificationStore`. 12 new tests (93 total). Phase 2 consumes `viewModel.waitingCount` (reactive computed over `@Published sessions`) for the header badge and `.waiting` for the row highlight.
