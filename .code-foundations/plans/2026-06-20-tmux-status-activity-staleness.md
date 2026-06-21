# Plan: tmux-status activity staleness + age display

**Created:** 2026-06-20
**Status:** complete
**Started:** 2026-06-20
**Completed:** 2026-06-20
**Complexity:** simple

---

## Context

**Problem:** The tmux-status generator (`.claude/skills/tmux-status/tmux-status.py`, run by the
headless `/tmux-status` slash command) is time-blind — it classifies window `statusKind` purely
from scrollback text and never reads tmux's last-activity time, so windows untouched for
hours-to-weeks render as `active`/`running` (open grug backlog `thegrid/tmux-status-accuracy-backlog`).
It also emits no per-window activity, so the dashboard cannot show how stale a window is. Two
adjacent bugs surfaced during diagnosis: the window-list parser (`split(None, 2)`) truncates
space-containing window names (`🤖 2.1.183` → `🤖`) and corrupts the active flag; and
`.claude/commands/tmux-status.md` points at `~/.claude/skills/tmux-status/tmux-status.py`, a path
that does not exist (the real script is repo-relative; the driver runs with `cwd=repo_dir`).

**Verified live:** tmux's `#{window_activity}` (epoch of last pane output) is populated and
discriminating — genuinely-active windows are 0–12s stale; false positives are hours–weeks.

## Constraints

- Build-first; 3–5 targeted tests max per feature; no e2e (project CLAUDE.md).
- Swift suite under `grid-notify/Tests/GridNotifyTests` is currently 100% green and must stay green.
- Back-compat: older status files omit `activity` — decode must be lenient (absent → 0).
- The staleness downgrade target is `idle`, NOT `waiting`. A mass flip into `waiting` would trip
  the existing waiting→notification feature (`TmuxDashboardViewModel` / `TmuxWaitingPolicy`) for
  every long-idle session at once. This is load-bearing.
- Staleness threshold: **300 seconds** (user-chosen).
- `activity == 0` (unknown) renders as *no age shown*, never a bogus "56y ago".

---

## Implementation Phases

### Phase 1: Generator + JSON contract
**Skills:** code-foundations:cc-defensive-programming
**Gate:** Standard

**Goal:** Make the Python generator time-aware — capture `#{window_activity}`, gate `active`/`running`
on a 300s staleness threshold, emit a per-window `activity` field — and fix the parse/path bugs that
block it, then update the contract spec docs.

**Scope:**
- IN: `.claude/skills/tmux-status/tmux-status.py` (list-windows format reorder so name is LAST +
  capture `window_activity`; thread `window_activity`+`now` into `analyze_pane`; **staleness gate
  applied INSIDE `analyze_pane`, at the end, just before it returns** — it already receives
  `window_activity`+`now`, so the override stays in one place; downgrade → `idle`; emit `activity`);
  fix script path in `.claude/commands/tmux-status.md`; add
  `windows[].activity` + staleness rule to the contract spec in `.claude/skills/tmux-status/SKILL.md`
  and `.claude/commands/tmux-status.md`.
- OUT: any Swift change; the user-facing `docs/TMUX_DASHBOARD.md`; grug (all Phase 2).

**Edge cases:**
- Window name with spaces/emoji → `split(None, 3)` keeps name intact as the last field; active flag correct.
- `window_activity` absent/0 → no staleness downgrade applied (guard `if window_activity and ...`).
- Empty pane (`content == ''`) early-returns `idle` before the gate — unaffected, still valid.
- `error` and already-`waiting`/`idle` kinds are never touched by the gate (only `active`/`running` downgrade).
- A genuinely active window streams output → `window_activity` is within seconds of `now` → stays `active`.

**Produces:** `tmux-status.json` `windows[]` objects gain `"activity": <int epoch>` (tmux
`#{window_activity}`), and any window whose `now - activity > 300` is emitted as `statusKind: "idle"`
(never `active`/`running`). This integer field + that guarantee is the contract Phase 2 consumes.

**Done when:**
- [ ] DW-1.1: `list-windows -F` format puts `#{window_name}` last and includes `#{window_activity}`; a
  window named `🤖 2.1.183` parses with full name and correct `active` bool (regression on the truncation bug).
- [ ] DW-1.2: A window with `now - window_activity > 300` and scrollback that would otherwise read
  `active`/`running` is emitted as `idle` with a `"idle — no output for <age>"` summary.
- [ ] DW-1.3: A window with `now - window_activity <= 300` retains its text-derived `active`/`running` kind.
- [ ] DW-1.4: Every emitted window object contains an integer `activity` field equal to its `#{window_activity}`.
- [ ] DW-1.5: `.claude/commands/tmux-status.md` invokes the script at a path that resolves from
  `cwd=repo_dir` (repo-relative, not `~/.claude/...`).
- [ ] DW-1.6: `SKILL.md` + command-md schemas document `windows[].activity` (int epoch) and the
  >300s staleness→idle rule.

### Phase 2: Swift consumer + age display + docs/grug
**Skills:** code-foundations:cc-defensive-programming
**Gate:** Standard

**Goal:** Consume the new `activity` field — decode it back-compatibly, format it as a relative age,
and render it in each window row — then record the change in the user doc and grug.

**Scope:**
- IN: `TmuxStatusModel.swift` (`TmuxWindow.activity: Int`, custom `init(from:)` with
  `decodeIfPresent ?? 0`, defaulted memberwise-init param); `TmuxDashboardViewModel.swift`
  (static `relativeAge(activity:now:) -> String?`); `TmuxDashboardView.swift`
  (`TmuxDashboardWindowRow` renders the age, muted/right-aligned); `docs/TMUX_DASHBOARD.md`
  (activity field + staleness behavior); grug (mark backlog fixed + record decisions).
- OUT: any generator change (Phase 1); the waiting→notification logic (untouched).

**Depends on:** Phase 1.
**Consumes:** `windows[].activity` (int epoch) from the Phase 1 JSON contract.

**Edge cases:**
- Status file written before this change omits `activity` → `decodeIfPresent ?? 0` → `relativeAge` returns nil → row shows no age (no decode failure, no bogus age).
- Existing test call sites build `TmuxWindow(...)` without `activity` → defaulted memberwise param keeps them compiling.
- `relativeAge`: `<60s`→"now", `<1h`→"Nm", `<1d`→"Nh", else "Nd"; negative diff (clock skew) → "now".
- The full data path still decodes via the synthesized/explicit `init(from:)` — `TmuxStatusKind` lenient decode unchanged.

**Produces:** Dashboard window rows display a relative last-activity age; nothing downstream consumes it.

**Done when:**
- [ ] DW-2.1: `TmuxWindow` decodes `activity` when present and defaults it to 0 when absent (back-compat).
- [ ] DW-2.2: `relativeAge(activity:now:)` returns nil for `activity == 0` and the correct
  "now"/"Nm"/"Nh"/"Nd" string otherwise; negative diff → "now".
- [ ] DW-2.3: `TmuxDashboardWindowRow` shows the age (when non-nil) without disturbing the
  existing name/`*`/summary/waiting-highlight layout.
- [ ] DW-2.4: `swift build` clean and the full `grid-notify` suite stays green (no regressions).
- [ ] DW-2.5: `docs/TMUX_DASHBOARD.md` documents the per-window `activity` + staleness behavior;
  grug backlog `thegrid/tmux-status-accuracy-backlog` is marked fixed and the gating/parse/path
  decisions are recorded.

---

## Test Coverage

**Level:** Targeted (project CLAUDE.md: 3–5 tests max; prove the approach, not coverage).

## Test Plan

- [ ] T1 (DW-2.1, clean): `TmuxWindow` decodes `activity` from JSON when present.
- [ ] T2 (DW-2.1, dirty/back-compat): `TmuxWindow` with no `activity` key decodes to `activity == 0` (no throw).
- [ ] T3 (DW-2.2, clean): `relativeAge` formats 30s→"now", 300s→"5m", 7200s→"2h", 172800s→"2d".
- [ ] T4 (DW-2.2, dirty): `relativeAge` returns nil for `activity == 0` and "now" for a negative diff.
- [ ] T5 (DW-1.2/1.4, generator): a temporary Python check (or live run) proving a >300s-stale window
  emits `idle` + an `activity` int, and a fresh window stays `active`; delete the temp check after (CLAUDE.md allows this).
- [ ] T6 (DW-1.1, dirty/parse regression): a temporary Python check parsing a mock `list-windows -F`
  line with a space/emoji name (`0 1 1781992914 🤖 2.1.183`) asserts the full name (`🤖 2.1.183`) and
  `active == True` survive the `split(None, 3)`; delete after.

---

## Notes

- Phase 1's format-string reorder fixes the name-truncation bug as a side effect of putting the
  variable-length name last — call it out so review doesn't read it as scope creep.
- The 300s gate only ever *downgrades* `active`/`running`→`idle`; it never promotes or flips to `waiting`,
  which is what keeps the waiting→notification feature quiet.
- grug context: `thegrid/tmux-dashboard-driver-gotchas` (driver runs `cwd=repo_dir`, logs to
  `thegrid-notify.json`), `thegrid/tmux-status-accuracy-backlog` (the bug being closed).
- Known pre-existing debt (OUT of scope, flagged by plan review): `write_atomic` hard-codes
  `~/.local/state/thegrid` and ignores `$XDG_STATE_HOME`, unlike the rest of the project. Not touched
  here — the default path matches, so it does not affect any DW item. Leave for a separate fix.

---

## Execution Log

### Phase 1: Generator + JSON contract (Gate: Standard)
- [x] BUILD: Discovery + design + implementation (stub → implement → validate) complete
- [x] REVIEW: Verification passed — POST-GATE PASS, all 6 DW items + edge cases with execution evidence (24/24 unit assertions, live 21-window run, 0 stale active/running)
- [x] Committed
Commit: e267dce
Summary: `tmux-status.py` is now time-aware — `list-windows -F` captures `#{window_activity}` with the window NAME moved LAST (new `parse_window_line` via `split(None, 3)` fixes the emoji/space name truncation + active-flag bug), `analyze_pane` applies a guarded 300s staleness gate at its tail that downgrades only `active`/`running` → `idle` (never `waiting`), and every emitted window carries an integer `activity`. Command script path fixed to repo-relative; `SKILL.md` + command-md document the `activity` field + staleness rule. **Contract for Phase 2:** `tmux-status.json` `windows[]` now include `"activity": <int epoch>` and no window stale > 300s is ever `active`/`running`.

### Phase 2: Swift consumer + age display (+ doc) (Gate: Standard)
- [x] BUILD: Discovery + design + implementation (stub → implement → validate) complete
- [x] REVIEW: Verification passed — POST-GATE PASS, all 5 DW items + 4 edge cases with execution evidence (swift build clean, 104/104 tests, baseline 100 → +4, no regressions)
- [x] Committed
Commit: 9ee027d
Summary: grid-notify now consumes the `activity` contract — `TmuxWindow` gains `activity: Int` with a custom `init(from:)` (`decodeIfPresent ?? 0`, mirroring `TmuxSession`) + defaulted memberwise param (existing call sites compile); `TmuxDashboardViewModel.relativeAge(activity:now:)` formats nil@0 / "now" / "Nm" / "Nh" / "Nd" (negative→"now"); `TmuxDashboardWindowRow` renders the age muted/right-aligned without disturbing the existing name/`*`/summary/waiting-highlight layout. `docs/TMUX_DASHBOARD.md` documents the field + staleness behavior. Orchestrator updated grug: `tmux-status-accuracy-backlog` marked RESOLVED and `tmux-dashboard-driver-gotchas` records the window_activity-gating + parse/path fixes. 4 new tests; full suite 104/104 green.
