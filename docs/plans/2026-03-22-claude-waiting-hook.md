# Plan: Claude Waiting Hook

**Created:** 2026-03-22
**Status:** ready
**Complexity:** simple

---

## Context

Add a `thegrid notify install-hook` command that sets up a Claude Code hook so that whenever Claude finishes and is idle, a notification appears in theGrid's notification panel. The hook resolves the terminal window by PID (parent process chain), querying theGrid's StateManager via CLI. Notification body includes tmux session:window and project directory. Enter on the notification focuses the correct terminal window.

## Constraints

- Window lookup by PID, not focused window or app name search
- `thegrid notify install-hook` does all setup -- user runs it once
- Hook script lives in `~/.local/share/thegrid/hooks/`
- Settings wired into `~/.claude/settings.json` (merges, doesn't overwrite)
- All metadata from theGrid CLI or tmux -- no osascript/AppleScript

---

## Implementation Phases

### Phase 1: Window lookup by PID
**Model:** sonnet

**Goal:** Add `thegrid window find --pid <PID>` CLI command that returns the window ID owned by a process.

**Scope:**
- IN: New RPC handler or extend existing `window.find` to accept `pid` param, CLI subcommand `thegrid window find --pid <PID>`
- OUT: Hook script, settings.json wiring

**File hints:**
- `grid-server/Sources/GridServer/MessageHandler.swift` -- existing window.find RPC handler
- `grid-server/Sources/GridCLI/` -- CLI subcommands

**Done when:**
- [ ] `thegrid window find --pid <PID>` returns the window ID for the process (JSON output)
- [ ] Returns error/empty if no window found for that PID
- [ ] Build passes

---

### Phase 2: Install-hook command
**Model:** sonnet

**Goal:** Add `thegrid notify install-hook` that creates the hook script and wires it into Claude Code settings.

**Scope:**
- IN: Hook shell script (resolves parent PID chain to terminal PID, calls `thegrid window find --pid`, gets tmux metadata, calls `thegrid notify push`), CLI subcommand that writes the script and adds Notification idle_prompt hook to `~/.claude/settings.json`
- OUT: Uninstall command (future)

**File hints:**
- `grid-server/Sources/GridCLI/NotifyCommand.swift` -- notify subcommands
- `~/.claude/settings.json` -- Claude Code hook config target

**Done when:**
- [ ] `thegrid notify install-hook` creates executable hook script at `~/.local/share/thegrid/hooks/claude-waiting.sh`
- [ ] Command adds Notification idle_prompt hook to `~/.claude/settings.json` (reads existing, merges, writes back)
- [ ] Hook script resolves terminal window by walking parent PID chain and querying theGrid
- [ ] Hook script includes tmux session:window and basename of cwd in notification body
- [ ] Running the hook manually produces a notification in the panel
- [ ] Build passes

---

## Test Coverage

**Level:** None (shell script + CLI wiring, verified manually)

## Test Plan

- [ ] Manual: `thegrid window find --pid $$` returns a window ID
- [ ] Manual: `thegrid notify install-hook` creates script and modifies settings
- [ ] Manual: Run hook script directly, notification appears in panel
- [ ] Manual: In a Claude Code session, Claude goes idle, notification appears

---

## Notes

- The hook script needs to walk the PID parent chain because the hook runs as a child of Claude Code, which is a child of the shell, which is a child of tmux, which is a child of the terminal app. The terminal app's PID is what theGrid tracks.
- `~/.claude/settings.json` may not exist yet -- the installer should create it if missing.
- The Notification event with idle_prompt matcher fires when Claude is waiting for user input.

---

## Execution Log

_To be filled during building_
