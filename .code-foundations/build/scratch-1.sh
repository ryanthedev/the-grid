#!/bin/bash
set -ex

cd /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/grid-notify

# Build and test
swift build
swift test
