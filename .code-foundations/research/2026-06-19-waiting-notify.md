# Research: tmux window enters `waiting` → notification + dashboard indicator

**Summary:** When a tmux window transitions INTO `statusKind=waiting` (needs user input),
grid-notify posts exactly one deduped notification to its existing notification panel and
flags the window on the dashboard with more than today's `⏸` glyph.

**Date:** 2026-06-19
**Status:** confirmed
**Source brief:** `/tmp/waiting-notify-brief.md`
**Feeds:** `/code-foundations:plan`

---

## Problem

theGrid's tmux dashboard (in `grid-notify`) renders every tmux session/window with an
AI-assigned `statusKind`. `waiting` means the window needs the user to unblock it (e.g. a
Claude Code session sitting at its prompt). Today that state is only a small `⏸` glyph in a
tree that can be long and is sorted by activity — easy to miss, and there's no push signal at
all. The original dashboard plan (`2026-06-16-tmux-status-dashboard.md`, Decision Log)
**explicitly deferred** "waiting → notification emission" as YAGNI. The user now wants it.

## Outcome if it works

The user gets a single, timely nudge the moment a window starts needing input, and an
at-a-glance dashboard signal (count + highlight) so blocked work is never buried.

---

## Confirmed requirements

### 1. Notification (into the existing panel)
- **Trigger:** a window transitions INTO `statusKind == .waiting` from any non-waiting kind.
- **Content:** title = `<target> needs input` (e.g. `work:0 needs input`); body = the window's
  AI `summary`.
- **Click action:** **none for v1.** (See "Focus action — decision" below for why, and the
  fallback the user pre-authorized.) A `detailCmd` (`tmux capture-pane -pt <target> -S -200`)
  is attached so the notification is still inspectable via the panel's existing Enter→detail
  pop-out — zero new machinery, reuses `DetailWindowController`.
- **Dedupe / re-arm:** exactly ONE notification per *waiting episode*. While the window stays
  `waiting`, no further notifications — even if its summary churns. It re-arms only after the
  window **leaves** `waiting` (different kind, or window/session disappears); a later
  re-entry into `waiting` notifies again.

### 2. Dashboard indicator (beyond `⏸`)
- **Header count badge:** a `N need input` badge/count in the dashboard header.
- **Highlighted row:** waiting window rows get a stronger treatment than the glyph alone —
  yellow tint / left accent bar — matching the existing `.waiting` systemYellow color.
- **NOT a pinned group.** Rejected by the user: a pinned "needs input" section would yank
  waiting windows out of the activity-based, newest-at-bottom sort that was just shipped
  (commits fd6c80f / fa7d1f6), fighting that ordering.

---

## Decisions (with rationale)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Indicator = header count badge **+** highlighted row; no pinned group | At-a-glance count + in-place emphasis without disturbing the activity sort |
| 2 | Notification = title + summary, **no click action**, with `detailCmd` for inspection | See focus-action decision below; user pre-authorized this fallback |
| 3 | Trigger = `.waiting` **only** (not `.error`) | `error` already renders red on the dashboard; keep v1 scope tight |
| 4 | Re-arm only when the window **leaves** `waiting` | One notification per waiting episode; no summary-churn spam |
| 5 | Detect the transition by **diffing each load** against the previous load in the viewModel | The status file is rewritten every ~60s; firing on every refresh would spam. Diff new-vs-previous to catch the *edge* into `waiting` |
| 6 | Dedupe key = window **`target`** (`session:index`) | Stable per-window identity already in the model; survives reordering |

### Focus action — decision and why

The user's first choice was "title + summary + **focus action** (click → jump to the blocked
tmux pane), reuse the existing window-focus path; fall back to no action if much more work."

Verified in code: the existing notification focus path is
`GridNotificationAction.focusWindow(windowID:)`, and in grid-notify it is a **documented
no-op** — `NotificationPanelWindow.swift:131-134` logs `warn.notify.action.focus` and returns
because focusWindow "requires grid-server's WindowManipulator and StateManager" which the
standalone grid-notify panel doesn't have. There is also **no existing mapping** from a tmux
`target` to the macOS terminal window/tmux client that hosts it, so a real "jump to the pane"
would need new, environment-specific machinery (terminal-app activation + `tmux switch-client`
with a resolved client). That is materially more work and out of scope for v1.

→ Falling back to **title + summary, no action**, per the user's explicit instruction. The
`detailCmd` (the same `tmux capture-pane` the dashboard's pane pop-out uses) preserves an
inspect affordance at no cost.

---

## How it grounds onto the existing code (verified)

- **Post a notification (internal, in-process):** `NotificationStore.upsert(_:)` /
  `add(_:)` (`NotificationStore.swift:148-185`). The store is an actor (thread-safe). The
  tmux watcher already delivers on the main queue and `load(_:)` runs on `@MainActor`, so the
  viewModel can post directly without new plumbing — no need for the pipe or the
  CLI→grid-server→DistributedNotification relay.
- **`GridNotification`** fields (`Notification.swift:82-163`): `id`, `source`, `title`,
  `body`, `priority`, `action?`, `detailCmd?`, `ttl`, `groupCount`, … — everything needed.
- **Transition detection seam:** `TmuxDashboardViewModel.load(_:)`
  (`TmuxDashboardViewModel.swift`) is the single funnel for every ~60s refresh and manual
  refresh. Diff the incoming `TmuxStatusData` against the previously-loaded one here.
- **`.waiting`** already exists in `TmuxStatusKind` (`TmuxStatusModel.swift:9-46`) with
  glyph `⏸` and `systemYellow`. Window identity = `TmuxWindow.target` (`"session:index"`).
- **Row + header rendering:** `TmuxDashboardView.swift` (`TmuxDashboardWindowRow` ≈ L195-260
  renders the glyph at ~L220; header is the place for the count badge).
- **Tests:** `grid-notify/Tests/GridNotifyTests/` — `TmuxDashboardTests.swift`,
  `NotificationStoreTests.swift` show the patterns; the transition/dedupe predicate should be
  a **pure helper** so it's unit-testable off the AppKit/actor boundary (per code-standards).

---

## Scope boundaries

- **IN:** transition+dedupe predicate (pure, tested); posting one notification on entry into
  `waiting`; header count badge; row highlight; re-arm on leaving `waiting`.
- **OUT (v1):** notification click-to-focus the pane; `error` (or other kinds) as triggers;
  re-notify on summary change; any pinned/reordered "needs input" group; changes to the
  status-file producer skill or the ~60s cadence.

## Riskiest assumptions

| Assumption | Confidence | Mitigation |
|---|---|---|
| `load(_:)` sees a *previous* state to diff (not reset between loads) | HIGH | viewModel is long-lived (window-bound); hold previous waiting-set as a stored property |
| First load after launch shouldn't fire for windows already waiting | MED | Treat the first load as a baseline (seed the set without notifying) — confirm in plan |
| Posting from `load(_:)` is safe re: store actor isolation | HIGH | store is an actor; call via `Task`; `load` is `@MainActor` |

## Open (defer to plan)
- First-load behavior: seed-without-notify vs notify-on-first-sight. Leaning **seed baseline,
  don't notify on the very first load** so a restart doesn't dump a notification per
  already-waiting window. To be locked in the plan.
