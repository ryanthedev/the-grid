#!/bin/bash
# Phase 2 post-gate: verify build
echo "=== Swift Build ==="
cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | tail -15
echo ""
echo "BUILD VERIFICATION COMPLETE"
