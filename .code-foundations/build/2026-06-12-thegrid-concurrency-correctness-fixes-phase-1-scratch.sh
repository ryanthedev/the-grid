#!/bin/bash
set -o pipefail

WORKTREE="/Users/r/repos/theGrid/.claude/worktrees/thegrid-concurrency-correctness-fixes/grid-server"
cd "$WORKTREE" || { echo "ERROR: could not cd to $WORKTREE"; exit 1; }

echo "=== swift build ==="
swift build 2>&1
BUILD_EXIT=$?
echo "Build exit code: $BUILD_EXIT"

echo ""
echo "=== swift test ==="
swift test 2>&1
TEST_EXIT=$?
echo "Test exit code: $TEST_EXIT"

exit $TEST_EXIT
