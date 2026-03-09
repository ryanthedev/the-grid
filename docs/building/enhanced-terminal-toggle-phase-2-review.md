# Review: Phase 2 - Launch args and initial sizing

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (manual verification per CLAUDE.md)

### Section-by-section mapping

**findTmux (pseudocode lines 36-52) -> implementation lines 155-184**
- [x] Checks paths in order: `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`
- [x] Falls back to `/usr/bin/which tmux` with Process + Pipe
- [x] Trims whitespace/newlines, checks non-empty
- [x] Last resort returns `"tmux"`

**matchesTerminalTitle (pseudocode lines 103-106) -> implementation lines 83-86**
- [x] Guards nil title
- [x] Returns `title == "grid:scratch" || title == "grid-terminal"`

**findTerminalWindow (pseudocode lines 85-100) -> implementation lines 51-80**
- [x] Fast path checks cached ID, verifies with `matchesTerminalTitle` and bundleID
- [x] Clears cache on miss
- [x] Slow path scans all windows with same title+bundleID checks
- [x] Returns nil when not found

**sizeAndCenterOnDisplay (pseudocode lines 57-80) -> implementation lines 190-221**
- [x] Guards windowManipulator availability
- [x] Gets visibleFrame with fallback to frame, returns early if neither
- [x] Calculates 80% width, 60% height
- [x] Gets display name and UUID from DisplayState
- [x] Fetches offset via `await MainActor.run { gridConfig?.getDisplayOffset(...) }`
- [x] Centers with offset applied (handles nil offset with `?? 0`)
- [x] Guards AX element acquisition
- [x] Sets frame via `setWindowFrame`
- [x] Logs `term.sized` with wid, width, height

**launchTerminal (pseudocode lines 111-154) -> implementation lines 227-292**
- [x] Guards stateManager and windowManipulator
- [x] Calls `findTmux()` for tmux path
- [x] Detects `$SHELL` with `/bin/zsh` fallback
- [x] Launch args match spec exactly:
  - `-na Ghostty.app --args`
  - `--title=grid:scratch`
  - `--window-decoration=none`
  - `--quit-after-last-window-closed=true`
  - `--env=GRID_TERMINAL=scratch`
  - `--command=SHELL -l -c 'TMUX new-session -A -s grid-scratch'`
- [x] Error handling on process launch with log and error return
- [x] Poll budget: 25 attempts x 200ms = 5s
- [x] Calls sizeAndCenterOnDisplay BEFORE layer+focus
- [x] Sets layer to `.above`
- [x] Focuses window
- [x] Logs `term.launched` with wid and attempts
- [x] Logs `err.term.timeout` on timeout
- [x] Returns appropriate CommandResult in all paths

**Unchanged sections (pseudocode line 156-157)**
- [x] toggle, toggleTerminalWindow, setup, init unchanged from Phase 1

## Dead Code
None found. All imports used (Foundation for Process/FileManager, CoreGraphics for CGRect/CGPoint). No commented-out blocks, no debug statements, no unreachable code after early returns.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 7 plan checklist items for Phase 2 mapped to implementation (title fix, launch args, shell wrapper, findTmux, sizeAndCenter, call ordering, poll budget) |
| Concurrency | PASS | GridConfig access correctly wrapped in `await MainActor.run`. Commands serialized through router per plan notes. No shared mutable state races -- `cachedTerminalWindowID` accessed only from toggle path which is serialized. |
| Error Handling | PASS | Process launch failure caught and logged with error return. `findTmux` catches `which` failure gracefully. `sizeAndCenterOnDisplay` guards all optionals and returns early on failure. Nil gridConfig handled with `?.` and `?? 0` fallback. |
| Resource Mgmt | PASS | Process objects are local scope, released when function returns. Pipe read is bounded (single-line `which` output). No persistent file handles or connections opened. |
| Boundaries | PASS | Nil display name handled (`?? ""`). Nil visibleFrame falls back to frame. Nil offset falls back to 0. Nil AX element returns early. Poll loop bounded at 25 attempts. PID fallback to 0 on line 267 is acceptable since `getAXElement` will simply fail gracefully. |
| Security | N/A | No untrusted user input. Shell path from process environment. Tmux path validated via FileManager existence check. No string interpolation into shell execution context (args passed as array elements to Process). |

## Defensive Programming
- **No empty catch blocks**: The `catch` in `findTmux` (line 178) is intentional fallthrough to the "last resort default" -- this is a non-critical fallback, not swallowing a bug. The comment documents the intent.
- **No silent failures**: All error paths either log (`jlog`) or return error CommandResults. `sizeAndCenterOnDisplay` returns silently on guard failures but this is correct -- sizing failure is non-fatal, the terminal still appears.
- **External input validated**: `$SHELL` environment variable used as Process argument array element (not shell-interpreted). `which tmux` output trimmed and checked for emptiness.
- **No assertions with side effects**: No assertions used.
- **No broad exception types**: Swift `catch` blocks are scoped to `Process.run()` calls only.
- **MainActor isolation respected**: `gridConfig?.getDisplayOffset` correctly accessed via `await MainActor.run` matching codebase pattern.
