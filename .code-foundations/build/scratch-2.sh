#!/bin/bash
set -e

cd /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/grid-notify

echo "=== Building ==="
swift build 2>&1

echo ""
echo "=== Running tests ==="
swift test 2>&1
