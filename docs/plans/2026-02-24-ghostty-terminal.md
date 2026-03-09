# Replace GridTerminal with Managed Ghostty Window

## Context

GridTerminal uses SwiftTerm (CPU-based CoreText rendering), which causes noticeable typing latency. Ghostty uses GPU-accelerated Metal rendering at 120fps. Rather than embedding libghostty (not yet available as a standalone view), we launch Ghostty as a regular window and manage it through existing grid-server RPCs.

The grid-server already has window manipulation capabilities (focus, minimize, layer, sticky, opacity). We just need to add **hide/show** (order out/in) and rewire the CLI `terminal` command.

## Changes

### 1. Add `orderWindowOut` to MSSClient
**File:** `grid-server/Sources/GridServer/MSSClient.swift`

Add a wrapper around `mss_window_order()` (already declared in `include/mss/mss.h:253`) with `MSS_ORDER_OUT`:
- `orderWindowOut(_ windowID: UInt32) -> Bool` — hides window without minimizing

The existing `orderWindowToFront` (line 270) handles the "show" case.

### 2. Add `window.isOrderedIn` RPC check
**File:** `grid-server/Sources/GridServer/MacOSAPIs.swift` (already has `SLSWindowIsOrderedIn` at line 54)
**File:** `grid-server/Sources/GridServer/MessageHandler.swift`

Add RPC method `window.isOrderedIn` that returns whether a window is currently visible (ordered in) using the existing `SLSWindowIsOrderedIn()` wrapper.

### 3. Add `window.hide` and `window.show` RPCs
**File:** `grid-server/Sources/GridServer/MessageHandler.swift`

- `window.hide` — calls `mssClient.orderWindowOut(windowID)`
- `window.show` — calls `mssClient.orderWindowToFront(windowID)` + `windowManipulator.focusWindow()`

### 4. Rewrite CLI `terminal` command
**File:** `grid-cli/cmd/grid/main.go`

New logic (replaces current detached-process approach):
1. Connect to grid-server, get snapshot
2. Find window where `Title == "grid-terminal"` AND `BundleID == "com.mitchellh.ghostty"`
3. **If not found:** launch Ghostty, poll for new window, configure it
   ```
   open -na Ghostty.app --args \
     --title=grid-terminal \
     --window-decoration=none \
     --quit-after-last-window-closed=true \
     -e tmux new-session -A -s grid-scratch
   ```
   Then set layer=above + sticky=true via RPCs
4. **If found:** check `window.isOrderedIn`
   - If visible → `window.hide`
   - If hidden → `window.show` + `window.focus`

### 5. Clean up
**File:** `grid-cli/cmd/grid/main.go`
- Remove `findTerminalExecutable()` function (lines 1944-1980)
- Update `terminalCmd` (lines 4360-4393)
- Keep in `shouldSkipMutex` skip list

**Build system:** Remove `grid-terminal` from `make dev` / `make install-dev` targets (Makefile). Keep the GridTerminal source around for now but stop building/deploying it.

## Verification

1. `make server && make run` — rebuild grid-server with new RPCs
2. `make cli` — rebuild CLI
3. `thegrid terminal` — should launch a Ghostty window with no decorations running tmux
4. `thegrid terminal` again — should hide the window
5. `thegrid terminal` again — should show the window
6. Verify window floats above other windows and appears on all spaces
7. Verify typing performance is noticeably better than old SwiftTerm terminal
