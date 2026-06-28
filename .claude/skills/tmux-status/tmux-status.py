#!/usr/bin/env python3
"""
tmux-status: Enumerate all tmux sessions and windows, analyze pane content,
and write JSON status file atomically to ~/.local/state/thegrid/tmux-status.json

Usage: python3 tmux-status.py
"""

import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

def get_timestamp():
    """Get current Unix timestamp."""
    return int(datetime.now().timestamp())

# Windows untouched for longer than this (seconds) are downgraded to idle
# regardless of what their scrollback text reads.
STALENESS_THRESHOLD = 300

def format_age(seconds):
    """Render an age in seconds compactly: Ns / Nm / Nh / Nd."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"

def parse_window_line(wline):
    """
    Parse one `list-windows -F '#{window_index} #{window_active} #{window_activity} #{window_name}'`
    line into (widx, wactive, wactivity, wname).

    The window NAME is LAST so split(None, 3) keeps space/emoji names intact
    (e.g. '🤖 2.1.183') instead of truncating at the first space. Returns None
    on a malformed line so the caller can skip it without aborting the run.
    """
    # tmux output is external (process boundary) input: tolerate malformed lines.
    wparts = wline.split(None, 3)
    if len(wparts) < 4:
        return None
    try:
        widx = int(wparts[0])
        wactive = wparts[1] == '1'
        wactivity = int(wparts[2])
    except (ValueError, IndexError):
        return None
    wname = wparts[3]
    return widx, wactive, wactivity, wname

def analyze_pane(content, window_name, session_name, window_idx, window_activity, now):
    """
    Analyze pane content to determine command, statusKind, and summary.

    statusKind values:
    - active: something is visibly happening (Claude typing, build running, editor with recent edits)
    - running: long-running process executing (server, watcher) without active changes
    - waiting: waiting for user input (Claude prompt, shell prompt, REPL ready)
    - idle: quiescent, no activity and no input prompt
    - error: pane capture failed or error visible

    Staleness gate (applied at the very end, just before returning): if the
    window's last pane output (window_activity) is older than STALENESS_THRESHOLD
    seconds, an otherwise-active/running window is downgraded to idle. Only
    active/running are ever downgraded — error/waiting/idle are never touched.
    """
    if not content:
        return 'unknown', 'idle', f"{window_name}"

    lines = content.split('\n')
    last_line = lines[-1] if lines else ''
    last_line_stripped = last_line.strip()

    # Extract command from window name (best guess)
    wname = window_name.lstrip('🤖 ').strip()
    command = wname.split()[0] if wname else 'unknown'
    if command.isdigit():
        command = 'unknown'

    # Detect patterns in content
    is_claude_session = '-- INSERT --' in content or 'Press Ctrl-C' in content or 'Permission rule' in content
    has_zsh_prompt = last_line_stripped.startswith('❯') or last_line_stripped.startswith('$')
    is_editor = 'nvim' in window_name.lower() or '-- INSERT --' in content
    is_running_metro = 'Metro' in content or 'expo run' in content or 'npm run' in content
    # Check for errors only in recent output (last 10 lines), not entire scrollback,
    # to avoid false positives from stale error messages in pane history
    recent_output = '\n'.join(lines[-10:]).lower()
    has_error = 'error' in recent_output or 'failed' in recent_output

    # Determine statusKind and summary
    if is_claude_session:
        if 'Press Ctrl-C' in content or 'Permission rule' in content or '❯' in last_line_stripped or '1. Yes' in content or '2. No' in content:
            # Claude Code at prompt or permission dialog waiting for user input
            statusKind = 'waiting'
            summary = 'claude waiting for input'
        elif '-- INSERT --' in last_line_stripped:
            # Claude Code in insert mode (entering text)
            statusKind = 'waiting'
            summary = 'claude waiting for input'
        else:
            # Claude Code actively processing
            statusKind = 'active'
            summary = 'claude session active'
    elif is_editor:
        # Vim/nvim editor active
        statusKind = 'active'
        summary = 'editor active'
    elif is_running_metro and not has_zsh_prompt:
        # Dev server (metro, expo, npm) running without prompt
        statusKind = 'running'
        summary = 'dev server running'
    elif has_zsh_prompt:
        # Shell at prompt waiting for command
        statusKind = 'waiting'
        summary = 'shell prompt waiting'
    elif has_error:
        # Error visible in output
        statusKind = 'error'
        summary = 'error visible'
    else:
        # Default: idle
        statusKind = 'idle'
        summary = f"{window_name}"

    # Staleness gate: a falsy/absent window_activity never triggers a downgrade.
    # active/running/error are downgraded to idle if no pane output for >STALENESS_THRESHOLD.
    # This prevents stale error messages in scrollback from being misclassified as active errors.
    if window_activity and statusKind in ('active', 'running', 'error'):
        age = now - window_activity
        if age > STALENESS_THRESHOLD:
            statusKind = 'idle'
            summary = f"idle — no output for {format_age(age)}"

    return command, statusKind, summary

def get_all_sessions_and_windows():
    """
    Collect all sessions, windows, and pane content.
    Returns dict with sessions list or empty list if tmux not running.
    """
    timestamp = get_timestamp()

    # Get session list with metadata
    try:
        result = subprocess.run(
            ['tmux', 'list-sessions', '-F',
             '#{session_name} #{session_activity} #{session_attached}'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return {'generatedAt': timestamp, 'sessions': []}
    except Exception:
        return {'generatedAt': timestamp, 'sessions': []}

    session_lines = result.stdout.strip().split('\n')
    if not session_lines or not session_lines[0]:
        return {'generatedAt': timestamp, 'sessions': []}

    sessions = []

    for line in session_lines:
        if not line.strip():
            continue

        parts = line.split()
        if len(parts) < 3:
            continue

        session_name = parts[0]
        try:
            activity = int(parts[1])
            attached = parts[2] != '0'
        except (ValueError, IndexError):
            continue

        # Get windows for this session
        windows = []
        try:
            wresult = subprocess.run(
                ['tmux', 'list-windows', '-t', session_name,
                 '-F', '#{window_index} #{window_active} #{window_activity} #{window_name}'],
                capture_output=True, text=True, timeout=5
            )
            if wresult.returncode == 0:
                for wline in wresult.stdout.strip().split('\n'):
                    if not wline.strip():
                        continue

                    # Name is parsed LAST so space/emoji names survive intact.
                    parsed = parse_window_line(wline)
                    if parsed is None:
                        continue

                    try:
                        widx, wactive, wactivity, wname = parsed

                        # Capture pane content
                        pane_content = ""
                        try:
                            presult = subprocess.run(
                                ['tmux', 'capture-pane', '-t',
                                 f"{session_name}:{widx}", '-p'],
                                capture_output=True, text=True, timeout=5
                            )
                            if presult.returncode == 0:
                                pane_content = presult.stdout
                        except Exception:
                            pass

                        # Analyze pane to get command, statusKind, summary.
                        # window_activity + the run timestamp drive the staleness gate.
                        command, status_kind, summary = analyze_pane(
                            pane_content, wname, session_name, widx,
                            wactivity, timestamp
                        )

                        windows.append({
                            'index': widx,
                            'name': wname,
                            'command': command,
                            'active': wactive,
                            'statusKind': status_kind,
                            'summary': summary,
                            'activity': wactivity or 0,
                            'target': f"{session_name}:{widx}"
                        })
                    except (ValueError, IndexError):
                        continue
        except Exception:
            pass

        sessions.append({
            'name': session_name,
            'attached': attached,
            'activity': activity,
            'windows': windows
        })

    return {
        'generatedAt': timestamp,
        'sessions': sessions
    }

def write_atomic(data):
    """Write JSON atomically: write to temp file, then rename to final path."""
    state_dir = Path.home() / '.local' / 'state' / 'thegrid'
    state_dir.mkdir(parents=True, exist_ok=True)

    temp_file = state_dir / 'tmux-status.json.tmp'
    final_file = state_dir / 'tmux-status.json'

    try:
        # Write to temp file
        with open(temp_file, 'w') as f:
            json.dump(data, f, indent=2)

        # Atomic rename (mv)
        temp_file.rename(final_file)
        print(f"✓ written to {final_file}")
        return True
    except Exception as e:
        print(f"✗ Error writing output: {e}", file=sys.stderr)
        return False

def main():
    """Main entry point."""
    data = get_all_sessions_and_windows()

    if not write_atomic(data):
        sys.exit(1)

if __name__ == '__main__':
    main()
