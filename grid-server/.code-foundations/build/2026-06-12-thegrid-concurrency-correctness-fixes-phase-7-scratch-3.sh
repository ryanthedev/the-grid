#!/bin/bash
set -o pipefail

cd /Users/r/repos/theGrid/.claude/worktrees/thegrid-concurrency-correctness-fixes/grid-server

echo "=== swift build ==="
swift build 2>&1
BUILD_STATUS=$?
echo "BUILD EXIT: $BUILD_STATUS"

echo ""
echo "=== swift test ==="
swift test 2>&1
TEST_STATUS=$?
echo "TEST EXIT: $TEST_STATUS"

exit $TEST_STATUS
