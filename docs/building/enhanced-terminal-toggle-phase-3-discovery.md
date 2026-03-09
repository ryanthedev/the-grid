# Discovery: Phase 3 - Per-display frame persistence

## Files Found
- `grid-server/Sources/GridServer/Grid/GridTerminal.swift` -- exists (293 lines), the sole file to modify
- `grid-server/Sources/GridServer/XDG.swift` -- exists, provides `XDG.stateHome` (returns `~/.local/state`)
- `grid-server/Sources/GridServer/StateModels.swift` -- exists, `DisplayState` has `visibleFrame: CGRect?`, `frame: CGRect?`, `uuid: String`
- `grid-server/Sources/GridServer/WindowManipulator.swift` -- exists, has `setWindowPosition(element:point:)`, `setWindowFrame(element:frame:)`, `getAXElement(pid:windowID:)`
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- exists, `getDisplayOffset(uuid:name:)` is `@MainActor`

## Current State
GridTerminal has a working toggle flow:
- `toggle()` -> `findTerminalWindow()` -> `toggleTerminalWindow()` or `launchTerminal()`
- **Hide path** (line 116): calls `orderWindowOut(windowID)` -- no frame saving
- **Show path** (lines 120-148): when moving cross-space, centers horizontally at `displayFrame.origin.y` (hardcoded top positioning). No per-display memory.
- **Launch path** (lines 264-267): calls `sizeAndCenterOnDisplay()` which does 80% x 60% sizing with display offset
- `sizeAndCenterOnDisplay()` (lines 190-221): calculates frame from scratch every time, uses `gridConfig.getDisplayOffset()` via `await MainActor.run`

No frame persistence exists today. Every show/cross-space-move re-centers the window.

## Gaps
1. No `TerminalFrame` struct -- needs to be created
2. No `terminalFrames` in-memory map -- needs to be added
3. No file path for `terminal-frame.json` -- needs computed property using `XDG.stateHome`
4. No `loadTerminalFrames()` / `saveTerminalFrames()` -- need to be created
5. Hide path does not save frame before hiding
6. Show path always re-centers instead of restoring saved position
7. No bounds checking on restore
8. No `term.position` log event

## Prerequisites
- [x] GridTerminal.swift exists and has clear toggle flow
- [x] XDG.stateHome available for file path
- [x] DisplayState has `visibleFrame` and `uuid` for bounds checking
- [x] WindowManipulator has `setWindowPosition` and `getAXElement` for positioning
- [x] WindowState has `frame: CGRect` for reading current window frame before hide
- [x] `wmState.metadata.activeDisplayUUID` available for keying frames
- [x] Phase 1 (extract class) and Phase 2 (launch args) completed

## Recommendation
BUILD -- all prerequisites met, clear modification points in existing code
