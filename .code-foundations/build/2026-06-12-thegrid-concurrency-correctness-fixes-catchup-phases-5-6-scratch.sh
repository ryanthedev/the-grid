#!/usr/bin/env bash
set -e
cd /Users/r/repos/theGrid/.claude/worktrees/thegrid-concurrency-correctness-fixes/grid-server

echo "=== SWIFT BUILD ==="
swift build 2>&1

echo ""
echo "=== SWIFT TEST ==="
swift test 2>&1
