#!/bin/bash
set -euo pipefail

WORKTREE=/Users/r/repos/theGrid/.claude/worktrees/thegrid-concurrency-correctness-fixes
cd "$WORKTREE/grid-server"

echo "=== swift build ==="
swift build 2>&1
BUILD_RC=$?
echo "--- build exit: $BUILD_RC ---"

echo ""
echo "=== swift test ==="
swift test 2>&1
TEST_RC=$?
echo "--- test exit: $TEST_RC ---"

exit $TEST_RC
