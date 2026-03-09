# Discovery: Phase 2 - Launch args and initial sizing

## Files Found
- `grid-server/Sources/GridServer/Grid/GridTerminal.swift` -- exists, created in Phase 1 (203 lines)
- `grid-server/Sources/GridServer/WindowManipulator.swift` -- exists, has `getAXElement()`, `setWindowFrame(element:frame:)`, `setWindowPosition(element:point:)`
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- exists, `@MainActor class GridConfig`, has `getDisplayOffset(uuid:name:)`
- `grid-server/Sources/GridServer/StateModels.swift` -- exists, `DisplayState` has `visibleFrame: CGRect?` and `frame: CGRect?`

## Current State

GridTerminal.swift (Phase 1 output) has:
- `findTerminalWindow(_:)` -- matches title `"grid-terminal"` and bundleID `"com.mitchellh.ghostty"`
- `launchTerminal()` -- uses `-e tmux new-session -A -s grid-scratch` args, 15 attempts x 200ms poll
- `toggleTerminalWindow(_:_:)` -- show/hide with cross-display repositioning, but only positions at top-center (no sizing)

Key APIs available:
- `WindowManipulator.setWindowFrame(element:frame:) -> Bool` -- sets both position and size via AX
- `WindowManipulator.getAXElement(pid:windowID:) -> AXUIElement?` -- gets AX element for manipulation
- `GridConfig.getDisplayOffset(uuid:name:) -> GridDisplayOffset` -- `@MainActor`, returns `{x: Double, y: Double}`
- Pattern for MainActor access: `await MainActor.run { gridConfig.getDisplayOffset(...) }`
- Display name lookup pattern: `wmState.displays.first(where: { $0.uuid == uuid })?.name ?? ""`

## Gaps

1. **Launch args use `-e` flag** -- Need to change to `--command=SHELL -l -c 'tmux ...'` format
2. **Title is `grid-terminal`** -- Need to change to `grid:scratch`, with fallback matching for transition
3. **No `findTmux()` helper** -- Need to search common paths, fall back to `which tmux`
4. **No initial sizing** -- Currently no sizing on launch; only repositioning on cross-display move
5. **Poll budget is 15 attempts (3s)** -- Plan wants 25 attempts x 200ms = 5s
6. **No `--quit-after-last-window-closed=true` arg** -- Ghostty stays running after closing, need this flag
7. **No `--env=GRID_TERMINAL=scratch` arg** -- Missing environment variable passthrough
8. **No shell detection** -- Needs `ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"`

## Prerequisites
- [x] GridTerminal.swift exists with Phase 1 implementation
- [x] WindowManipulator APIs available (setWindowFrame, getAXElement)
- [x] GridConfig display offset API available (@MainActor)
- [x] DisplayState has visibleFrame/frame fields
- [x] Existing pattern for MainActor.run in other Grid* files

## Recommendation
BUILD -- All dependencies exist. Changes are localized to GridTerminal.swift. APIs for sizing and display offset are well-established in the codebase.
