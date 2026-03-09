#!/bin/bash
# Post-gate phase 1: verify GridTerminalManager compiles
cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | tail -30
echo "EXIT CODE: $?"
