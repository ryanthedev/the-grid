# Review: Final Comprehensive - Enhanced Terminal Toggle

## Verdict: PASS

All three phases implemented correctly. Two minor pre-existing findings noted below (not blockers).

## Spec Match

### Phase 1 (server-terminal-toggle): Extract to GridTerminal class
- [x] `GridTerminal` class with empty init, `setup()`, weak deps -- matches Grid* pattern
- [x] `toggle()` as single public entry point
- [x] `findTerminalWindow()` with cached ID fast path + slow scan
- [x] `toggleTerminalWindow()` with visibility + active-space checks, hide/show logic
- [x] `launchTerminal()` with Process launch + polling loop
- [x] All terminal code removed from GridCommandRouter (no leftover methods/properties)
- [x] Router delegates to `gridTerminal.toggle()` at line 184
- [x] main.swift creates `GridTerminal()` at line 161, passes to router at line 182

### Phase 2 (enhanced-terminal-toggle): Launch args, sizing, tmux discovery
- [x] `findTmux()` -- checks 3 paths, falls back to `which`, then bare `tmux`
- [x] `sizeAndCenterOnDisplay()` -- 80%x60% sizing, display offset, AX frame set
- [x] `matchesTerminalTitle()` -- matches both "grid:scratch" and legacy "grid-terminal"
- [x] Launch args updated: `--title=grid:scratch`, `--window-decoration=none`, `--quit-after-last-window-closed=true`, `--env=GRID_TERMINAL=scratch`, `--command=` with login shell wrapping tmux
- [x] Poll budget increased to 25 attempts (5s total)
- [x] Sizing happens before layer+focus in launch path

### Phase 3 (enhanced-terminal-toggle): Per-display frame persistence
- [x] `TerminalFrame` Codable struct with x, y, width, height
- [x] `terminalFrames` dict + `terminalFramesLoaded` lazy-load flag
- [x] `terminalFramePath` computed from XDG.stateHome
- [x] `loadTerminalFrames()` -- lazy load, silent on missing file, logs on decode error
- [x] `saveTerminalFrames()` -- prettyPrinted JSON, atomic write, logs on error
- [x] Hide path saves frame before orderWindowOut (lines 132-144)
- [x] Show path attempts restore with bounds check, falls back to center with offset (lines 158-224)
- [x] `sizeAndCenterOnDisplay` unchanged (launch-only, no persistence needed)

### No unplanned additions
All code in GridTerminal.swift maps to a pseudocode section across the three phases. No extra public API surface.

## Dead Code

### None found in GridTerminal.swift
All methods are reachable:
- `toggle()` called from router
- `findTerminalWindow()` called from toggle and launchTerminal poll loop
- `toggleTerminalWindow()` called from toggle
- `launchTerminal()` called from toggle
- `loadTerminalFrames()` called from hide and show paths
- `saveTerminalFrames()` called from hide path
- `findTmux()` called from launchTerminal
- `sizeAndCenterOnDisplay()` called from launchTerminal poll success
- `matchesTerminalTitle()` called from findTerminalWindow (both paths)

No unused imports, no commented-out blocks, no debug statements.

### GridCommandRouter.swift clean
Only 6 terminal-related references remain, all correct:
- `gridTerminal` property declaration (line 45)
- `gridTerminal` init parameter (line 67)
- `self.gridTerminal = gridTerminal` (line 81)
- `gridTerminal.setup(...)` call (line 125)
- `case "terminal"` dispatch (line 183)
- `gridTerminal.toggle()` delegation (line 184)

No leftover `handleTerminal`, `findTerminalWindow`, `toggleTerminalWindow`, or `launchTerminal` methods.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All pseudocode sections across 3 phases mapped to implementation (see above) |
| Concurrency | PASS | GridTerminal is a plain class consistent with all Grid* modules. Commands serialized through router dispatch. Mutable state (cachedTerminalWindowID, terminalFrames, terminalFramesLoaded) only accessed from the async toggle path which is single-entry. No shared mutable state across threads. |
| Error Handling | PASS | Process launch: caught, logged, returns error (lines 372-374). File read failure: silent return with empty dict (lines 247-249). JSON decode failure: logged warning, keeps empty dict (lines 255-257). File write failure: logged warning, non-fatal (lines 266-268). Timeout: logged and returned as error (lines 410-411). All guard-else paths return `.error()` with descriptive messages. |
| Resource Mgmt | PASS | Process in findTmux: waitUntilExit called (line 291). Pipe read: readDataToEndOfFile completes before return (line 292). Launch process: fire-and-forget via `open -na` (appropriate -- macOS manages the child). No long-lived file handles. No unclosed resources. |
| Boundaries | PASS | Empty windows dict: findTerminalWindow returns nil, launchTerminal fires. Nil display/visibleFrame: guarded by optional binding throughout show path. Missing activeSpaceID: onActiveSpace defaults to false, space move skipped. Saved frame out-of-bounds: bounds check (lines 176-180) covers all four edges, falls back to center. Empty terminalFrames: show path uses center mode. UInt32 parse failure in scan: guarded by `if let wid = UInt32(widStr)` (line 88). |
| Security | N/A | No untrusted external input. Terminal frame file is local. Ghostty launch args are hardcoded strings. tmux path resolved from known filesystem locations. |

## Defensive Programming

**Crisis invariants:**
- No executable code in assertions: No assertions used. All checks use guard/if-let/optional binding.
- No empty catch blocks: The `catch` in findTmux (line 298-300) has an explanatory comment and falls through to a default return. Load/save catches both log warnings with error details.
- External input validated: JSON file from disk decoded inside do/catch with typed decoder. Malformed data caught and logged.

**Silent failure check:**
- `loadTerminalFrames()` silently returns on missing file (line 247-249): Correct -- no file means no saved frames, not an error.
- `saveTerminalFrames()` logs on failure (line 267): Non-fatal, appropriate for frame persistence.
- `setWindowPosition` and `setWindowFrame` return values discarded: Consistent with codebase-wide pattern for AX manipulation calls (checked GridFocus, GridApply -- same pattern).
- `orderWindowOut`, `orderWindowToFront`, `setWindowLayer` return values discarded: Same pattern throughout codebase.

**Weak reference guards:**
- `stateManager` guarded in `toggle()` (line 49) and `launchTerminal()` (line 348)
- `windowManipulator` guarded in `toggleTerminalWindow()` (line 113), `sizeAndCenterOnDisplay()` (line 315), `launchTerminal()` (line 349)
- `gridConfig` accessed via optional chaining (`gridConfig?.getDisplayOffset`) in lines 207 and 327

No critical defensive violations found.

## Code Style

- All comments on their own line above code -- never inline to the right. Verified all 50+ comment lines.
- No force unwraps (`!`) anywhere in the file.
- Section separators (`// ====`) consistent with GridCommandRouter and other Grid* modules.
- Method ordering: public (toggle) -> private find -> private toggle -> private persistence -> private helpers -> private launch. Logical grouping.

## Pre-existing Findings (not introduced by terminal toggle)

### 1. `shouldShutdown` written but never read (main.swift:92)
**Status:** Pre-existing. This variable exists in the signal handling setup and is set in both SIGINT and SIGTERM handlers (lines 210, 221), but never read. The handlers call `Darwin.exit(0)` directly, making the flag redundant. This predates all terminal toggle work -- the signal handling block was not modified in any terminal toggle phase.

### 2. Stale `grid-terminal` pkill on startup (main.swift:46-49)
**Status:** Pre-existing / vestigial. The `pkill -9 -f grid-terminal` on server startup was for the old SwiftTerm-based GridTerminal binary. Since Ghostty-based terminals are identified by title "grid:scratch", this pkill would not affect them. It is harmless dead code from the SwiftTerm era. Not introduced by this feature.

## Summary

GridTerminal.swift is a clean, well-structured 413-line module that follows established codebase patterns exactly. All three phases of pseudocode are faithfully implemented. The router correctly delegates. main.swift wiring is correct. No dead code, no build warnings introduced, no defensive programming violations.
