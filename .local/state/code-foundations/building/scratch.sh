#!/bin/bash
set -e
cd /Users/r/repos/theGrid/.claude/worktrees/hexagonal-port-protocols/grid-server

echo "=== swift build ==="
swift build 2>&1
echo "BUILD_EXIT=$?"

echo ""
echo "=== swift test ==="
swift test 2>&1
echo "TEST_EXIT=$?"
