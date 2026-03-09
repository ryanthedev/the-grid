# Plan: grid-terminal - Floating Scratchpad Terminal

**Created:** 2026-02-07
**Status:** complete

## Context

theGrid needs a floating scratchpad terminal (Quake/Guake-style) toggled via BFD hotkey. This is the first in a planned suite of popup tools. The terminal attaches to a persistent tmux session ("grid-scratch"), staying alive across toggle cycles. Built as a standalone binary following the GridPicker pattern.

## Constraints

- Separate binary (GridServer uses `.prohibited` activation policy, can't show interactive windows)
- SwiftTerm for terminal engine (PTY + VT parser + rendering)
- Long-lived daemon process (unlike ephemeral GridPicker)
- PID file with flock for single-instance enforcement
- NSDistributedNotification for CLI-to-daemon toggle signaling
- tmux session "grid-scratch" (create-or-attach via `tmux new-session -A -s grid-scratch`)
- Centered on current display, GridPicker visual style (borderless, floating, rounded corners, dark bg)
- No shared GridPopup module yet (extract when building second tool)

## Chosen Approach

**PID File + Persistent PTY** - Atomic single-instance via PID file with flock at `~/.local/state/thegrid/grid-terminal.pid`. PTY/tmux spawned immediately on daemon start. Toggle via NSDistributedNotification. tmux session survives daemon crashes (reattaches on next launch).

## Implementation Checklist

### Phase 1: SwiftPM Target + Minimal Window

- [ ] Add SwiftTerm dependency to `grid-server/Package.swift`
- [ ] Add `GridTerminal` executable target depending on SwiftTerm
- [ ] Create `grid-server/Sources/GridTerminal/main.swift` with:
  - NSApplication setup (`.regular` activation policy)
  - Floating borderless window matching GridPicker style
  - Colors struct (same values as GridPicker)
  - BackgroundView with rounded corners
  - Hardcoded center-of-screen positioning
  - `canBecomeKey = true`, `canBecomeMain = false`
- [ ] Add `terminal` Makefile target: `swift build --product grid-terminal`
- [ ] Verify: `make terminal && grid-server/.build/debug/grid-terminal` shows empty floating window

**Files:** `grid-server/Package.swift`, `grid-server/Sources/GridTerminal/main.swift`, `Makefile`

### Phase 2: SwiftTerm Integration + tmux Attach

- [ ] Embed `LocalProcessTerminalView` in the floating window
- [ ] Spawn `tmux new-session -A -s grid-scratch` as the PTY process
- [ ] Handle tmux not installed (check `which tmux` on startup, print error and exit if missing)
- [ ] Handle tmux session disconnect/exit (show message or respawn)
- [ ] Set terminal size to match window dimensions
- [ ] Handle window resize -> terminal resize

**Files:** `grid-server/Sources/GridTerminal/main.swift`

### Phase 3: Single-Instance + Toggle

- [ ] PID file logic at `~/.local/state/thegrid/grid-terminal.pid`
- [ ] Register for `DistributedNotificationCenter.default()` notification `"com.thegrid.terminal.toggle"`
- [ ] Toggle handler: `window.isVisible ? hide() : show()`
- [ ] Do NOT dismiss on focus loss (unlike GridPicker)

**Files:** `grid-server/Sources/GridTerminal/main.swift`

### Phase 4: CLI Command

- [ ] Add `terminalCmd` to `grid-cli/cmd/grid/main.go`
- [ ] Add `findTerminalExecutable()` following `findPickerExecutable()` pattern
- [ ] Add `thegrid terminal` to `shouldSkipMutex()` skipExact map
- [ ] Wire up in `init()` with `rootCmd.AddCommand(terminalCmd)`

**Files:** `grid-cli/cmd/grid/main.go`

### Phase 5: Build Integration

- [ ] Add `terminal` target to Makefile (debug build)
- [ ] Add `terminal-universal` target (release universal binary)
- [ ] Update `dev` target to include `terminal`
- [ ] Update `install-dev` target to copy grid-terminal to `~/.local/bin/`
- [ ] Update `dist-universal` target to include grid-terminal

**Files:** `Makefile`
