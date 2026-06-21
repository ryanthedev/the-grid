# Discovery + Design: Phase 1 - Generator + JSON contract

## Files Found
- `.claude/skills/tmux-status/tmux-status.py` (7553 bytes, exec) — the generator. Direct `tmux` subprocess calls (NOT MCP). This is what the `/tmux-status` command actually runs.
- `.claude/commands/tmux-status.md` — the slash-command driver. Invokes the Python script via Bash; currently points at `~/.claude/skills/tmux-status/tmux-status.py` (broken path).
- `.claude/skills/tmux-status/SKILL.md` — the skill doc + JSON contract spec. Written around an MCP execution model (`mcp__claude-mux__tmux`), but its "JSON schema" / "Field types" tables ARE the contract Phase 2 consumes.
- `docs/code-standards.md` — Swift-only conventions; relevant rule for Python: comments on their own line above code, never inline trailing. Test naming `test_DW_<phase>_<item>_<descriptor>`.

## Current State
`tmux-status.py` is time-blind. `analyze_pane(content, window_name, session_name, window_idx)` classifies `statusKind` purely from scrollback text. The window-list subprocess uses format `'#{window_index} #{window_name} #{window_active}'` and parses with `wparts = wline.split(None, 2)` — which truncates space/emoji names (name is the MIDDLE field, so `split(None, 2)` stops at the first space inside the name and mis-assigns `window_active`). No `activity` field is captured or emitted per window. `get_timestamp()` already provides `now` (int epoch).

Live verification (run during discovery):
- `tmux list-windows -F '#{window_index} #{window_active} #{window_activity} #{window_name}'` → `0 1 1781989787 🤖 2.1.183`. `now` was `1782008277` → that window is ~18490s stale, currently mis-rendered as `active`.
- `~/.claude/skills/tmux-status/tmux-status.py` does NOT exist; the repo-relative path does. Confirms DW-1.5 path bug.

## Gaps
| # | Gap | Resolution |
|---|-----|------------|
| 1 | Window list format has name in the MIDDLE; `split(None, 2)` truncates space/emoji names + corrupts `active`. | Reorder format to `#{window_index} #{window_active} #{window_activity} #{window_name}` (name LAST), parse with `split(None, 3)`. The name being last is what fixes truncation — NOT scope creep (plan Notes line 141). |
| 2 | No `window_activity` captured; `analyze_pane` never sees a time. | Capture activity int from the new field; thread `window_activity` + `now` into `analyze_pane`. |
| 3 | No staleness gate; long-idle windows render `active`/`running`. | Gate INSIDE `analyze_pane`, at the very end before return: `if window_activity and statusKind in ('active','running')` and `now - window_activity > 300` → downgrade to `idle` with `"idle — no output for <age>"` summary. |
| 4 | No per-window `activity` in emitted JSON. | Add `'activity': wactivity` to each window dict. |
| 5 | Command-md script path `~/.claude/...` does not resolve from `cwd=repo_dir`. | Change to repo-relative `.claude/skills/tmux-status/tmux-status.py`. |
| 6 | SKILL.md + command-md schemas omit `windows[].activity` and the staleness rule. | Add the field + the >300s→idle rule to both contract specs. |

Note: SKILL.md's *execution steps* describe MCP (`mcp__claude-mux__tmux`) while the live generator uses direct `tmux`. That mismatch is pre-existing and OUT of this phase's scope — I only touch SKILL.md's contract tables (schema/field-types), per the plan's "add windows[].activity + staleness rule to the contract spec".

## Code Standards
- Python comments on their own line above the code, never inline trailing (project CLAUDE.md rule, mirrored in code-standards §1).
- Test naming: `test_DW_<phase>_<item>_<descriptor>` (code-standards §5).
- No project Python test harness; per CLAUDE.md write 3–5 targeted temp tests, prove the approach, delete after. Report exact commands + output as evidence.

## Test Infrastructure
No pytest/unittest harness for this standalone script. Plan: a temporary `pytest`-free Python script using plain `assert` (Python 3.14.5 available), importing `analyze_pane` and a small parse helper from the generator, plus a live run of the real script to inspect emitted JSON. Delete the temp script after validating.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-1.1 | `list-windows -F` format puts `#{window_name}` last + includes `#{window_activity}`; `🤖 2.1.183` parses full name + correct `active`. | COVERED | `test_DW_1_1_emoji_name_survives_split` — parse mock line `0 1 1781992914 🤖 2.1.183` via the parse helper; assert name == `🤖 2.1.183`, active == True, activity == 1781992914. Plus assert the script's format string is name-last. |
| DW-1.2 | `now - activity > 300` + active/running scrollback → `idle` with `"idle — no output for <age>"`. | COVERED | `test_DW_1_2_stale_active_downgrades_to_idle` — `analyze_pane(claude_active_content, …, window_activity=now-9999, now=now)` → statusKind == `idle`, summary startswith `"idle — no output for"`. |
| DW-1.3 | `now - activity <= 300` retains text-derived active/running. | COVERED | `test_DW_1_3_fresh_active_stays_active` — same content, `window_activity=now-5` → statusKind == `active`. Plus a fresh running case stays `running`. |
| DW-1.4 | Every emitted window object has int `activity` == its `#{window_activity}`. | COVERED | `test_DW_1_4_live_json_has_int_activity` — run the real script live; load JSON; assert every `windows[].activity` is an int. |
| DW-1.5 | command-md invokes script at a path that resolves from `cwd=repo_dir` (repo-relative). | COVERED | `test_DW_1_5_command_md_path_repo_relative` — read `.claude/commands/tmux-status.md`; assert it contains `.claude/skills/tmux-status/tmux-status.py` and NOT `~/.claude/skills/tmux-status/tmux-status.py`. |
| DW-1.6 | SKILL.md + command-md schemas document `windows[].activity` (int epoch) + >300s→idle rule. | COVERED | `test_DW_1_6_contract_docs_document_activity` — read both docs; assert each mentions `activity` field + the `300`s staleness→idle rule. |

**Count check:** 6 DW-IDs in prompt, 6 in table. **All items COVERED:** YES

## Design Decisions

### Defensive programming (skill APPLIER) — where the data crosses a boundary
`tmux` subprocess output is **external input** (process boundary). The script already error-handles it: `try/except`, `returncode` checks, `if len(wparts) < N: continue`, `try: int(...) except (ValueError, IndexError): continue`. This is the right strategy (robustness — an internal dev tool, McConnell "log/skip and continue"); I extend it, not replace it:
- Parse `wactivity` with the same guarded `int()` conversion that already wraps `widx`/`wactive`. A malformed/absent activity field must NOT abort the window or the run.
- The staleness gate is guarded `if window_activity and statusKind in ('active','running')` — an absent/0 activity (falsy) never triggers a downgrade (DW edge case, plan line 61). This is error-handling-not-assertion: missing activity is an *anticipated* runtime condition (older tmux, race), not a programmer bug.
- No executable code in assertions, no empty catches introduced. Existing `except: pass` on pane capture is pre-existing and out of scope (it degrades to empty content → early `idle` return, which is safe).

### Gate placement (load-bearing, from plan)
The gate lives INSIDE `analyze_pane`, at the very end, just before `return command, statusKind, summary`. `analyze_pane` receives `window_activity` + `now` as new params. Single override point. Only `active`/`running` are ever downgraded; `error`, `waiting`, `idle` are never touched. Empty-content early-return (`if not content`) happens BEFORE the gate, so empty panes stay `idle` untouched.

### Signature change
`analyze_pane(content, window_name, session_name, window_idx)` → `analyze_pane(content, window_name, session_name, window_idx, window_activity, now)`. Two appended params (keeps existing positional call site readable; defaulting is unnecessary since the sole caller is updated in lockstep). Total params = 6 — at the code-standards threshold but justified: they are the full input the classifier needs and the gate must live here per the plan.

### Age formatting for the summary
`"idle — no output for <age>"`. `<age>` = `now - window_activity` seconds rendered compactly: `<60s`→`Ns`, `<3600`→`Nm`, `<86400`→`Nh`, else `Nd`. A tiny local helper `_format_age(seconds)`. Integer math, no deps. (Phase 2 has its own Swift `relativeAge`; this Python one is only for the generator's summary string and is independent.)

### Format string + parse
- Window list format: `'#{window_index} #{window_active} #{window_activity} #{window_name}'`.
- Parse: `wparts = wline.split(None, 3)`; require `len(wparts) >= 4`; `widx=int(wparts[0])`, `wactive = wparts[1]=='1'`, `wactivity=int(wparts[2])`, `wname=wparts[3]` (name kept whole, spaces/emoji intact).
- Extract a small module-level `parse_window_line(wline)` helper returning `(widx, wactive, wactivity, wname)` or `None`, so DW-1.1 is unit-testable off tmux. (Pure-function extraction mirrors code-standards §7 "pure decision module" ethos.)

### What does NOT change
Session-list format/parse (`session_activity`/`attached`) untouched. `write_atomic`, MCP-related SKILL.md execution steps, all Swift — untouched (out of scope). `summary` text for non-stale windows unchanged.

## Prerequisites
- [x] Required files exist
- [x] `tmux` available + `#{window_activity}` populated (verified live)
- [x] Python 3.14.5 available
- [x] No missing prerequisites

## Recommendation
BUILD — straightforward, all six DW items COVERED, no plan conflicts. Reorder the window-list format (name last) + capture activity; thread activity+now into `analyze_pane`; add the guarded 300s gate at the end of `analyze_pane`; emit `activity`; fix the command-md script path; document the field + rule in both contract specs.
