#!/usr/bin/env bash
set -uo pipefail
cd /Users/r/repos/theGrid/.claude/worktrees/waiting-notify/grid-notify || exit 1

echo "===== swift build ====="
swift build 2>&1
echo "build exit: $?"

echo "===== swift test ====="
swift test 2>&1
echo "test exit: $?"
