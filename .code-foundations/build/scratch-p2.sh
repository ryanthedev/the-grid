#!/usr/bin/env bash
set -uo pipefail
cd /Users/r/repos/theGrid/.claude/worktrees/waiting-notify/grid-notify
echo "===== swift build ====="
swift build 2>&1
echo "BUILD_EXIT=$?"
echo "===== swift test ====="
swift test 2>&1
echo "TEST_EXIT=$?"
