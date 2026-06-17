#!/bin/bash
set -e
cd /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/grid-notify
echo "=== BUILDING ==="
swift build
echo ""
echo "=== RUNNING TESTS ==="
swift test 2>&1
