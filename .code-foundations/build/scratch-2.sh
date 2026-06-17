#!/bin/bash
set -e
cd /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/grid-notify
echo "=== Building ==="
swift build
echo ""
echo "=== Running tests ==="
swift test
