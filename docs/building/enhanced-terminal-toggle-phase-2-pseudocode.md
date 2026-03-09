# Pseudocode: Phase 2 - Launch args and initial sizing

## Files to Create/Modify
- `grid-server/Sources/GridServer/Grid/GridTerminal.swift` (MODIFY)

## Design: findTmux + sizeAndCenter + launch args

### Approaches Considered
1. **Inline everything** -- Put tmux resolution, shell detection, and sizing all inside `launchTerminal()` as local logic
2. **Small private helpers** -- Extract `findTmux()`, `sizeAndCenterOnDisplay(...)` as separate private methods; keep `launchTerminal()` as orchestrator
3. **Configuration struct** -- Create a `TerminalLaunchConfig` struct that pre-computes all launch parameters, then pass it around

### Comparison
| Criterion | 1 (Inline) | 2 (Helpers) | 3 (Config struct) |
|-----------|-----------|-------------|-------------------|
| Interface simplicity | Same (toggle only) | Same (toggle only) | Same but adds a type |
| Readability of launchTerminal | Poor -- long method | Good -- clear steps | Moderate -- indirection |
| Reusability of sizing | None | sizeAndCenter usable from toggleTerminalWindow too | Over-engineered for one caller |
| Information hiding | All hidden | All hidden | All hidden |

### Choice: Approach 2 (Small private helpers)
Rationale: `findTmux()` and `sizeAndCenterOnDisplay()` are distinct responsibilities. Extracting them keeps `launchTerminal()` readable and lets `sizeAndCenterOnDisplay` potentially be called from the show path in future phases. No new types needed.

### Depth Check
- Interface methods: still 1 (`toggle`)
- Hidden details: tmux path resolution, shell detection, Ghostty launch args, display sizing math, display offset, poll budget
- Common case complexity: simple -- caller says `toggle()`, gets result

## Pseudocode

### GridTerminal.swift (MODIFY)

#### New private helper: findTmux

```
private func findTmux() -> String
    // Check common installation paths in order
    For each path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        If FileManager.default.fileExists(atPath: path)
            Return path

    // Fall back to `which tmux` for non-standard locations
    Create Process for /usr/bin/which with argument "tmux"
    Set up a Pipe for stdout
    Try to run, wait for exit
    Read stdout data, trim whitespace/newlines
    If result is non-empty
        Return result

    // Last resort default
    Return "tmux"
```

#### New private helper: sizeAndCenterOnDisplay

```
private func sizeAndCenterOnDisplay(windowID: UInt32, pid: pid_t, display: DisplayState) async
    Guard windowManipulator is available
    Guard we can get visibleFrame (fall back to frame, fall back to return early)

    // Calculate 80% x 60% of visible frame
    Let winW = visibleFrame.width * 0.8
    Let winH = visibleFrame.height * 0.6

    // Get display offset from config (@MainActor)
    Let displayName = display.name ?? ""
    Let displayUUID = display.uuid
    Let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }

    // Center on display, applying offset
    Let x = visibleFrame.origin.x + (visibleFrame.width - winW) / 2 + offset.x
    Let y = visibleFrame.origin.y + (visibleFrame.height - winH) / 2 + offset.y

    // Apply frame via AX
    Guard we can get AX element for (pid, windowID)
    Let frame = CGRect(x: x, y: y, width: winW, height: winH)
    _ = windowManipulator.setWindowFrame(element: element, frame: frame)

    jlog("term.sized", data: { wid, width: winW, height: winH })
```

#### Modified: findTerminalWindow

```
private func findTerminalWindow(wmState) -> UInt32 or nil
    // Fast path: check cached ID
    If cached ID exists
        Look up window in wmState by cached ID
        If window exists AND matchesTerminalTitle(win.title) AND app bundleID is ghostty
            Return cached ID
        Else
            Clear cache

    // Slow path: scan all windows
    For each window in wmState.windows
        If matchesTerminalTitle(win.title) AND app bundleID is ghostty
            Cache the window ID
            Return the window ID

    Return nil

// Helper to match both new and legacy title
private func matchesTerminalTitle(_ title: String?) -> Bool
    Guard title is not nil
    Return title == "grid:scratch" || title == "grid-terminal"
```

#### Modified: launchTerminal

```
private func launchTerminal() async -> CommandResult
    Guard stateManager and windowManipulator are available

    // Resolve paths
    Let tmuxPath = findTmux()
    Let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    // Build the launch command
    Create Process for /usr/bin/open
    Set arguments:
        "-na", "Ghostty.app",
        "--args",
        "--title=grid:scratch",
        "--window-decoration=none",
        "--quit-after-last-window-closed=true",
        "--env=GRID_TERMINAL=scratch",
        "--command=\(shell) -l -c '\(tmuxPath) new-session -A -s grid-scratch'"

    Try to run process
    If launch fails, log error and return error result

    // Poll for the terminal window to appear (25 attempts x 200ms = 5s)
    Let maxAttempts = 25
    For attempt in 0..<maxAttempts
        Sleep 200ms
        Get fresh wmState from stateManager
        If findTerminalWindow finds the window
            // Size and center on active display BEFORE setting layer and focus
            If we can determine the active display from wmState
                await sizeAndCenterOnDisplay(windowID, pid, display)

            // Set layer to above
            _ = windowManipulator.mssClient.setWindowLayer(windowID, layer: .above)

            // Focus the window
            If we can get the win from wmState
                _ = windowManipulator.focusWindow(pid, windowID)

            jlog("term.launched", data: { wid, attempts: attempt + 1 })
            Return ok "terminal launched"

    jlog("err.term.timeout")
    Return error "terminal launch timed out"
```

#### Unchanged: toggle, toggleTerminalWindow, setup, init
No changes to these methods in this phase.

## Design Notes
- `findTmux()` is synchronous -- file existence checks and a single `which` subprocess are fast enough to not warrant async
- `sizeAndCenterOnDisplay` takes a `DisplayState` rather than looking up the display itself -- the caller already has access to wmState and can pass the right display
- Title matching uses a helper `matchesTerminalTitle` to centralize the fallback logic -- both the fast path (cached) and slow path (scan) need it
- The `--command=` arg wraps tmux in a login shell so the terminal inherits the user's PATH and environment; this replaces the bare `-e tmux ...` which didn't go through a login shell
- Display offset is fetched via `await MainActor.run { ... }` matching the established pattern in GridApply and GridWindowMove
- Sizing happens BEFORE layer+focus so the window doesn't visually jump from default size to final size

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (helper extraction, deep module check)
- [x] Ready for implementation
