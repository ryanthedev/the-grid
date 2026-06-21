#!/bin/bash
# Phase 2 post-gate review — execute build + full test suite.
set -uo pipefail

cd /Users/r/repos/theGrid/grid-notify || exit 1

echo "===== SWIFT BUILD ====="
swift build 2>&1 | tail -20
echo "BUILD EXIT: ${PIPESTATUS[0]}"

echo ""
echo "===== SWIFT TEST ====="
swift test 2>&1 | tail -45
echo "TEST EXIT: ${PIPESTATUS[0]}"
