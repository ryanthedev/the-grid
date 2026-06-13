#!/bin/bash
set -euo pipefail

WORKTREE=/Users/r/repos/theGrid/.claude/worktrees/thegrid-concurrency-correctness-fixes/grid-server

echo "=== swift build ==="
cd "$WORKTREE" && swift build 2>&1

echo ""
echo "=== swift test ==="
cd "$WORKTREE" && swift test 2>&1
