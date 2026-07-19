#!/usr/bin/env bash
set -uo pipefail

SCRIPT=/Users/r/repos/theGrid/.claude/skills/tmux-status/tmux-status.py
OUT="$HOME/.local/state/thegrid/tmux-status.json"

echo "===== PY VERSION ====="
python3 --version

echo
echo "===== LIVE RUN ====="
python3 "$SCRIPT"
echo "exit=$?"

echo
echo "===== NOW (date +%s) ====="
NOW=$(date +%s)
echo "now=$NOW"

echo
echo "===== VALIDATE OUTPUT: every window has int activity; no stale active/running ====="
NOW=$NOW python3 - "$OUT" <<'PY'
import json, os, sys
now = int(os.environ["NOW"])
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
assert isinstance(data.get("generatedAt"), int), "generatedAt not int"
total_windows = 0
violations = []
stale_violations = []
for s in data.get("sessions", []):
    for w in s.get("windows", []):
        total_windows += 1
        act = w.get("activity")
        if not isinstance(act, int):
            violations.append((s["name"], w.get("name"), repr(act)))
        else:
            age = now - act
            if act and age > 300 and w.get("statusKind") in ("active", "running"):
                stale_violations.append((s["name"], w.get("name"), w.get("statusKind"), age))
print(f"total windows: {total_windows}")
print(f"windows missing int activity: {len(violations)}")
for v in violations:
    print("   MISSING-INT:", v)
print(f"stale (>300s) windows still active/running: {len(stale_violations)}")
for v in stale_violations:
    print("   STALE-NOT-DOWNGRADED:", v)
# Show a sample of windows with their age + statusKind
print("--- sample windows (name | statusKind | activity | age_s | summary) ---")
shown = 0
for s in data.get("sessions", []):
    for w in s.get("windows", []):
        if shown >= 12:
            break
        act = w.get("activity")
        age = (now - act) if isinstance(act, int) and act else None
        print(f"   {w.get('name')!r} | {w.get('statusKind')} | {act} | {age} | {w.get('summary')!r}")
        shown += 1
print("OK_LIVE" if not violations and not stale_violations else "FAIL_LIVE")
PY

echo
echo "===== UNIT TESTS: parse_window_line + analyze_pane ====="
python3 - <<'PY'
import importlib.util, sys, time

spec = importlib.util.spec_from_file_location(
    "tmuxstatus",
    "/Users/r/repos/theGrid/.claude/skills/tmux-status/tmux-status.py",
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = []
def check(name, cond, detail=""):
    print(f"[{'PASS' if cond else 'FAIL'}] {name} {detail}")
    if not cond:
        failures.append(name)

# --- DW-1.1 + edge: full emoji/space name as LAST field ---
parsed = m.parse_window_line("0 1 1781992914 🤖 2.1.183")
check("DW1.1 parse returns tuple", parsed is not None, repr(parsed))
if parsed:
    widx, wactive, wactivity, wname = parsed
    check("DW1.1 index=0", widx == 0, f"got {widx}")
    check("DW1.1 active True", wactive is True, f"got {wactive}")
    check("DW1.1 activity=1781992914", wactivity == 1781992914, f"got {wactivity}")
    check("DW1.1 name full '🤖 2.1.183'", wname == "🤖 2.1.183", f"got {wname!r}")

# inactive flag
p2 = m.parse_window_line("3 0 1700000000 my window with spaces")
check("edge name-with-spaces intact", p2 is not None and p2[3] == "my window with spaces", repr(p2))
check("edge active=False when '0'", p2 is not None and p2[1] is False, repr(p2))

# malformed -> None
check("malformed <4 fields -> None", m.parse_window_line("0 1") is None)
check("non-int index -> None", m.parse_window_line("x 1 100 name") is None)

# --- analyze_pane: Claude-active scrollback ---
# is_claude_session triggers on '-- INSERT --' or 'Press Ctrl-C'.
# To get 'active' (not waiting) we need is_claude_session True but
# neither 'Press Ctrl-C' nor '-- INSERT --' on the LAST stripped line.
claude_active = "esc to interrupt\nthinking...\nrunning -- INSERT -- somewhere above\nmore output"
now = int(time.time())

# DW-1.3 / edge fresh: now-5 stays active
cmd, kind, summ = m.analyze_pane(claude_active, "claude", "sess", 0, now - 5, now)
check("DW1.3 fresh(now-5) stays active", kind == "active", f"got kind={kind} summ={summ!r}")

# DW-1.2 / stale: now-9999 -> idle with 'no output for' summary
cmd, kind, summ = m.analyze_pane(claude_active, "claude", "sess", 0, now - 9999, now)
check("DW1.2 stale(now-9999) -> idle", kind == "idle", f"got kind={kind}")
check("DW1.2 stale summary form", summ.startswith("idle — no output for"), f"got {summ!r}")

# edge: window_activity = 0 -> NO downgrade (still active)
cmd, kind, summ = m.analyze_pane(claude_active, "claude", "sess", 0, 0, now)
check("edge activity=0 no downgrade (active kept)", kind == "active", f"got kind={kind}")

# running case: metro dev server, no prompt, stale -> idle; fresh -> running
metro = "Metro waiting on port 8081\nbundling\nsome log line"
cmd, kind, summ = m.analyze_pane(metro, "server", "sess", 1, now - 5, now)
check("running fresh stays running", kind == "running", f"got kind={kind} summ={summ!r}")
cmd, kind, summ = m.analyze_pane(metro, "server", "sess", 1, now - 9999, now)
check("running stale -> idle", kind == "idle", f"got kind={kind}")

# edge: waiting NEVER downgraded even when stale
waiting_pane = "some output\nPress Ctrl-C to interrupt"
cmd, kind, summ = m.analyze_pane(waiting_pane, "claude", "sess", 0, now - 9999, now)
check("edge waiting stays waiting when stale", kind == "waiting", f"got kind={kind} summ={summ!r}")

# edge: error NEVER downgraded.
# Need a pane that classifies as 'error': has 'error'/'failed', not claude, not editor,
# not metro, no zsh prompt, last line not a prompt.
error_pane = "build failed: something broke\ncompilation error here\ndetails details"
cmd, kind, summ = m.analyze_pane(error_pane, "build", "sess", 2, now - 9999, now)
check("edge error pane stays error when stale", kind == "error", f"got kind={kind} summ={summ!r}")

# edge: idle stays idle when stale (no special summary rewrite from gate)
idle_pane = "just some quiescent text\nnothing happening\nplain line"
cmd, kind, summ = m.analyze_pane(idle_pane, "misc", "sess", 3, now - 9999, now)
check("edge idle stays idle when stale", kind == "idle", f"got kind={kind} summ={summ!r}")

# edge: empty content early-returns idle, unaffected by gate (even with stale activity)
cmd, kind, summ = m.analyze_pane("", "emptywin", "sess", 4, now - 9999, now)
check("edge empty content -> idle early return", kind == "idle", f"got kind={kind}")
check("edge empty content summary is window_name", summ == "emptywin", f"got {summ!r}")

# edge: genuinely active (within seconds) stays active (already covered by fresh, explicit here)
cmd, kind, summ = m.analyze_pane(claude_active, "claude", "sess", 0, now - 1, now)
check("edge now-1 active stays active", kind == "active", f"got kind={kind}")

# boundary: exactly 300s age -> NOT downgraded (gate is strict >)
cmd, kind, summ = m.analyze_pane(claude_active, "claude", "sess", 0, now - 300, now)
check("boundary age==300 NOT downgraded (active)", kind == "active", f"got kind={kind}")
# boundary: 301s -> downgraded
cmd, kind, summ = m.analyze_pane(claude_active, "claude", "sess", 0, now - 301, now)
check("boundary age==301 downgraded (idle)", kind == "idle", f"got kind={kind}")

print()
print("ALL_UNIT_PASS" if not failures else f"UNIT_FAILURES: {failures}")
sys.exit(1 if failures else 0)
PY
echo "unit_exit=$?"

echo
echo "===== DW-1.5: command-referenced script path exists relative to repo root ====="
cd /Users/r/repos/theGrid
if [ -f ".claude/skills/tmux-status/tmux-status.py" ]; then
  echo "PASS: .claude/skills/tmux-status/tmux-status.py exists relative to repo root"
else
  echo "FAIL: referenced path does not resolve from repo root"
fi

echo
echo "===== Syntax / lint sanity (py_compile) ====="
python3 -m py_compile "$SCRIPT" && echo "py_compile OK" || echo "py_compile FAIL"
