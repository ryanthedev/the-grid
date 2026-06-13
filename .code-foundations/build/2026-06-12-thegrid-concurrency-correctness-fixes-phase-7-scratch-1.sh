#!/bin/bash
set -e
cd /Users/r/repos/theGrid/.claude/worktrees/thegrid-concurrency-correctness-fixes/grid-server
echo "=== swift build ==="
swift build 2>&1
echo "=== swift test ==="
swift test 2>&1
echo "=== DONE ==="
