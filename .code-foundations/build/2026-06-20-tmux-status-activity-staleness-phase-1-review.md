# Review: Phase 1 - tmux-status activity staleness

## Executed Results (Step 0)
- Test suite (generated, no committed harness): `bash .code-foundations/build/2026-06-20-tmux-status-activity-staleness-phase-1-scratch.sh` → 24/24 unit assertions PASS (`ALL_UNIT_PASS`, `unit_exit=0`); live run wrote 21 windows, `OK_LIVE` (0 windows missing int `activity`, 0 stale `active`/`running`).
- Typecheck: N/A (untyped standalone Python script).
- Lint: no linter configured for the project (ruff/flake8/pylint not installed, no `ruff.toml`/`pyproject.toml`/`setup.cfg`). Static check available = `python3 -m py_compile` → `py_compile OK`.

Environment: Python 3.14.5. `now` at live run = 1782008635 (from `date +%s`).

## Requirement Fulfillment

### DW-1.1
PREMISE:  The `tmux list-windows -F` format string puts `#{window_name}` LAST and includes `#{window_activity}`; a window-list line for `🤖 2.1.183` parses with the FULL name (not truncated to `🤖`) and correct `active` bool.
EVIDENCE: format string `tmux-status.py:181` (`'#{window_index} #{window_active} #{window_activity} #{window_name}'`); parser `parse_window_line` `tmux-status.py:33-53` (`wline.split(None, 3)`, name is `wparts[3]`).
TRACE:    `"0 1 1781992914 🤖 2.1.183"` → `split(None,3)` → `['0','1','1781992914','🤖 2.1.183']` → `(0, True, 1781992914, '🤖 2.1.183')`. Live run row: `'🤖 2.1.183' | ... | 1781989787`.
VERDICT:  PASS — unit assertions "DW1.1 name full '🤖 2.1.183'", "DW1.1 active True", "DW1.1 activity=1781992914" all PASS; full emoji name confirmed in live output.

### DW-1.2
PREMISE:  A window whose `now - window_activity > 300` and whose scrollback would otherwise classify as `active`/`running` is emitted as `idle` with summary `"idle — no output for <age>"`.
EVIDENCE: `tmux-status.py:128-132` — `if window_activity and statusKind in ('active','running'): age = now - window_activity; if age > STALENESS_THRESHOLD: statusKind='idle'; summary=f"idle — no output for {format_age(age)}"`. `STALENESS_THRESHOLD=300` (`:21`).
TRACE:    Claude-active scrollback, `window_activity = now-9999`, kind classifies `active` → `age=9999 > 300` → `idle`, summary `"idle — no output for 2h"`. Metro/running scrollback, `now-9999` → `idle`. Live output shows downgraded windows e.g. `'🤖 2.1.181' | idle | ... | 'idle — no output for 4h'`.
VERDICT:  PASS — unit assertions "DW1.2 stale(now-9999) -> idle", "DW1.2 stale summary form", "running stale -> idle" PASS.

### DW-1.3
PREMISE:  A window whose `now - window_activity <= 300` retains its text-derived `active`/`running` kind (gate does NOT downgrade fresh windows).
EVIDENCE: `tmux-status.py:128-132` — downgrade only when `age > 300`.
TRACE:    Claude-active scrollback, `now-5` → `age=5`, not `>300` → stays `active`. Metro scrollback, `now-5` → stays `running`. Boundary `now-300` → `age=300`, not `>300` → stays `active`.
VERDICT:  PASS — unit assertions "DW1.3 fresh(now-5) stays active", "running fresh stays running", "boundary age==300 NOT downgraded (active)" PASS.

### DW-1.4
PREMISE:  Every emitted window object contains an integer `activity` equal to its `#{window_activity}`.
EVIDENCE: `tmux-status.py:224` — `'activity': wactivity`, where `wactivity = int(wparts[2])` (`:49`). Malformed lines return `None` and are skipped (`:190-192`), so no window is emitted without a parsed int.
TRACE:    Live run validator parsed all 21 windows; `windows missing int activity: 0`. Each `activity` equals the third tmux field.
VERDICT:  PASS — live validation `OK_LIVE`, 0 windows missing int `activity` across 21 windows.

### DW-1.5
PREMISE:  `.claude/commands/tmux-status.md` invokes the script at a repo-relative path that resolves from repo root (NOT `~/.claude/...`); the path must exist.
EVIDENCE: `.claude/commands/tmux-status.md:11,14` — `python3 .claude/skills/tmux-status/tmux-status.py` (repo-relative, comment "the command runs with `cwd=repo_dir`").
TRACE:    `cd /Users/r/repos/theGrid` → `test -f .claude/skills/tmux-status/tmux-status.py` → exists.
VERDICT:  PASS — scratch check "PASS: .claude/skills/tmux-status/tmux-status.py exists relative to repo root". No `~/.claude/...` reference in the invocation.

### DW-1.6
PREMISE:  Both SKILL.md and the command md document the `windows[].activity` field (int epoch) AND the >300s → `idle` downgrade rule.
EVIDENCE: SKILL.md:71 (`windows[].activity` | integer | `#{window_activity}` ... gates staleness), SKILL.md:92-100 ("Staleness rule (time-aware override)", `generatedAt - windows[].activity > 300` → `idle`). command md:51-53 (int `activity` = `#{window_activity}`), command md:63-70 ("Staleness gate", `generatedAt - activity > 300` → `idle`, summary `"idle — no output for <age>"`).
TRACE:    grep confirms both files contain the int-`activity` field definition and the 300s downgrade rule including the missing/`0` guard.
VERDICT:  PASS — both files document the field type and the staleness rule, including the "never downgrade error/waiting/idle" and "missing/0 → no downgrade" clauses.

**All requirements met:** YES

## Test-DW Coverage
- [x] All DW items have corresponding execution evidence ran in Step 0.
  - DW-1.1 → parse unit assertions + live emoji-name row.
  - DW-1.2 → stale-downgrade unit assertions (claude + metro) + live downgraded rows.
  - DW-1.3 → fresh-retention unit assertions + boundary `age==300`.
  - DW-1.4 → live validator (0 missing int across 21 windows).
  - DW-1.5 → repo-relative path existence check.
  - DW-1.6 → grep-verified doc strings in both files (desk-checkable spec assertion; observed via grep on exact lines).
- [x] Coverage matches stated level (Targeted, 3-5 tests; 24 focused assertions + 1 live run, proving the approach, not coverage).

## Dead Code
None found. `analyze_pane` signature carries `session_name` and `window_idx` params that are unused inside the function — these are accepted, non-blocking (consistent with the schema/seam contract; no unreachable code, no debug prints, no commented-out blocks). Noted below.

## Correctness Dimensions
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | N/A | Single-threaded synchronous script; the only shared resource is the output file, written via temp-then-rename (`tmux-status.py:249-258`) which is atomic on one filesystem. No async/threads. |
| Error Handling | PASS | External `tmux` boundaries guarded: `subprocess.run` returncode checks + `except Exception` fallbacks (`:144-153, 184-208, 229-230`); malformed window lines → `None` and skipped (`:43-53, 190-192`); session lines with `<3` fields or non-int skipped (`:166-174`). No empty catch swallows a bug silently — each fallback degrades to a documented behavior (empty `sessions`, skipped line, empty pane). Write failure returns False → `sys.exit(1)` (`:261-263, 269-270`). |
| Resources | PASS | Pane/session subprocess calls bounded by `timeout=5`; temp file opened via `with` context manager (`:254-255`), closed before rename. No leaked handles. |
| Boundaries | PASS | `wline.split(None, 3)` caps at 4 fields so names with spaces/emoji survive (DW-1.1); `last_line = lines[-1] if lines else ''` guards empty split; gate guarded by `if window_activity and ...` so `0`/absent activity never underflows into a spurious downgrade; `format_age` covers s/m/h/d ranges. Boundary `age>300` (strict) verified at 300 (kept) and 301 (downgraded). |
| Security | N/A | No untrusted network/PII/auth input; `tmux` output is local-process text, validated at the parse barricade (`parse_window_line`, int-coercion with try/except). Output written under `$HOME/.local/state`. No injection surface (subprocess args are fixed lists, not shell strings). |

## Notes (non-blocking)
1. `analyze_pane` accepts `session_name` and `window_idx` but does not use them. Harmless; keeps the call site self-documenting. Not a FAIL (no requirement forbids it; no dead/unreachable code).
2. Live output shows two stale windows (`'🤖 2.1.183'` age 87501s, `'🤖 2.1.177'` age 255908s) whose summary is the bare window name rather than `"idle — no output for <age>"`. This is CORRECT per DW-1.2: those panes classified as `idle` from their text (not `active`/`running`), so the gate never engaged to rewrite the summary. DW-1.2 only governs windows that would *otherwise* read `active`/`running`. Their `statusKind` is `idle`, satisfying the invariant. The summary-rewrite is intentionally coupled to an actual downgrade. No defect.
3. Defensive-programming skill (CHECKER lens): the parse barricade validates external `tmux` text at entry with int-coercion guarded by try/except; no side-effecting assertions; no empty catch blocks (every `except` degrades to a defined behavior). Aligns with cc-defensive-programming rules for a robustness-leaning internal tool.
4. `STALENESS_THRESHOLD = 300` is a named module constant, matching the documented value in both md files — single source of truth, easy to keep docs and code in sync.

## Issues (if FAIL)
None.

**Verdict: PASS**
