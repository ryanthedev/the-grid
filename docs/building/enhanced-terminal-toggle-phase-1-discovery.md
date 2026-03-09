# Discovery: Phase 1 - Extract GridTerminal class

## Files Found
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- exists, contains terminal logic at lines 685-831
- `grid-server/Sources/GridServer/Grid/GridFocus.swift` -- exists, reference for Grid* pattern (init + setup + weak deps)
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` -- exists, another Grid* pattern reference
- `grid-server/Sources/GridServer/main.swift` -- exists, wires Grid* modules at lines 153-180
- `grid-server/Sources/GridServer/Grid/GridTerminal.swift` -- DOES NOT EXIST (to be created)

## Current State

Terminal toggle logic lives entirely in GridCommandRouter.swift:
- `cachedTerminalWindowID: UInt32?` (line 47) -- cached window ID for fast lookup
- `handleTerminal()` (line 685) -- entry point, dispatches to find/toggle/launch
- `findTerminalWindow(_:)` (line 697) -- scans WMState for Ghostty window with title "grid-terminal"
- `toggleTerminalWindow(_:_:)` (line 728) -- show/hide logic with space-aware repositioning
- `launchTerminal()` (line 783) -- spawns Ghostty process, polls for window appearance

The router dispatch at line 177-178 calls `handleTerminal()` directly.

Dependencies used by terminal code:
- `stateManager` (via `getState()`) -- to get WindowManagerState
- `windowManipulator` (via `.mssClient`, `.focusWindow()`, `.getAXElement()`, `.setWindowPosition()`) -- window operations
- No use of `gridConfig` currently (plan notes "for future phases")

Grid* pattern (from GridFocus.swift):
- `class GridFocus { init() {} }` with empty init
- `func setup(gridState:gridConfig:stateManager:windowManipulator:)` sets `private weak var` deps
- Dependencies stored as optional weak vars, unwrapped with guard at usage sites

Router init pattern (lines 56-131):
- Accepts all Grid* instances as constructor params
- Calls `.setup(...)` on each in the init body
- Stores as `private let` properties

## Gaps

1. **No plan file named "enhanced-terminal-toggle"** -- The user's prompt describes the plan inline. The closest existing plan is `2026-02-27-terminal-toggle-fix.md` which is a different (CLI-side) plan about positioning bugs. This phase is a server-side refactor.
2. **gridConfig dependency** -- Plan says to include it in setup() "for future phases" even though current code doesn't use it. This is fine -- forward-looking dependency injection.
3. **No behavioral change expected** -- Pure refactor, all logic moves unchanged.

## Prerequisites
- [x] GridCommandRouter.swift exists with terminal code to extract
- [x] Grid* pattern well-established (GridFocus, GridWindowMove, etc.)
- [x] main.swift wiring pattern clear
- [x] Dependencies identified (stateManager, windowManipulator, gridConfig)
- [x] No external dependencies needed

## Recommendation
BUILD -- Straightforward extraction refactor. All source files exist, pattern is well-established, dependencies are clear.
