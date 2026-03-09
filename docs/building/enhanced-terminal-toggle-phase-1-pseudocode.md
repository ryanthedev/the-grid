# Pseudocode: Phase 1 - Extract GridTerminal class

## Files to Create/Modify
- `grid-server/Sources/GridServer/Grid/GridTerminal.swift` (NEW)
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` (MODIFY)
- `grid-server/Sources/GridServer/main.swift` (MODIFY)

## Design: GridTerminal

### Approaches Considered
1. **Exact Grid* pattern** -- `init() {}` + `setup(stateManager:windowManipulator:gridConfig:)` with weak deps, single `toggle()` method
2. **Constructor injection** -- Pass deps in init like GridRecorder does: `init(stateManager:windowManipulator:gridConfig:)`
3. **Protocol-based** -- Define a TerminalToggling protocol, implement with concrete class

### Comparison
| Criterion | 1 (Grid* pattern) | 2 (Constructor) | 3 (Protocol) |
|-----------|-------------------|-----------------|---------------|
| Consistency with codebase | Best -- matches GridFocus etc. | Inconsistent -- only GridRecorder uses this | Over-engineered |
| Interface simplicity | 1 method | 1 method | 1 method + protocol |
| Weak ref cycle safety | Yes (weak vars) | No (strong refs) | Depends |

### Choice: Approach 1 (Grid* pattern)
Rationale: Consistency with established codebase pattern. The weak var + setup() pattern exists for a reason (breaking circular dependencies in the router init).

### Depth Check
- Interface methods: 1 (`toggle`)
- Hidden details: cached window ID, window scanning, toggle show/hide logic, Ghostty launch + polling, space-aware repositioning
- Common case complexity: simple -- caller says `toggle()`, gets result

## Pseudocode

### Grid/GridTerminal.swift (NEW)

```
class GridTerminal

    // Dependencies set via setup(), stored as weak optionals
    private weak stateManager: StateManager
    private weak windowManipulator: WindowManipulator
    private weak gridConfig: GridConfig

    // Cached terminal window ID for fast lookup (avoids full scan)
    private cachedTerminalWindowID: UInt32 or nil

    init() -- empty

    func setup(stateManager, windowManipulator, gridConfig)
        Store each dependency as weak reference

    func toggle() async -> CommandResult
        // Get current window manager state
        Get wmState from stateManager

        // Try to find existing terminal window
        If findTerminalWindow returns a window ID
            Return toggleTerminalWindow(windowID, wmState)
        Else
            Return launchTerminal()

    private func findTerminalWindow(wmState) -> UInt32 or nil
        // Fast path: check cached ID
        If cached ID exists
            Look up window in wmState by cached ID
            If window exists AND title is "grid-terminal" AND app bundleID is ghostty
                Return cached ID
            Else
                Clear cache (window gone or changed identity)

        // Slow path: scan all windows
        For each window in wmState.windows
            If title is "grid-terminal" AND app bundleID is ghostty
                Cache the window ID
                Return the window ID

        Return nil

    private func toggleTerminalWindow(windowID, wmState) async -> CommandResult
        Look up window state
        Determine visibility from isHidden flag (inverted)
        Determine if window is on active space (check spaces contains activeSpaceID)

        If visible AND on active space
            Order window out (hide)
            Log "term.hide"
            Return ok "terminal hidden"
        Else
            If there is an active space AND window not on it
                Move window to active space via mssClient
                // Reposition onto active display after cross-display move
                If we can find the active display and get AX element
                    Center horizontally on display visible frame
                    Position at top of display
                    Set window position via AX

            Order window to front (show)
            Set window layer to above
            Focus the window
            Log "term.show"
            Return ok "terminal shown"

    private func launchTerminal() async -> CommandResult
        Create Process for /usr/bin/open
        Set arguments: -na Ghostty.app --args --title=grid-terminal
            --window-decoration=none -e tmux new-session -A -s grid-scratch

        Try to run process
        If launch fails, log error and return error result

        // Poll for terminal window to appear (up to 3 seconds)
        For 15 attempts, 200ms apart
            Get fresh wmState from stateManager
            If findTerminalWindow finds the window
                Set window layer to above
                Focus the window
                Log "term.launched" with attempt count
                Return ok "terminal launched"

        Log timeout error
        Return error "terminal launch timed out"
```

### Grid/GridCommandRouter.swift (MODIFY)

```
Changes:
1. ADD private let gridTerminal: GridTerminal to properties
2. REMOVE cachedTerminalWindowID property
3. ADD gridTerminal parameter to init()
4. ADD gridTerminal.setup(stateManager, windowManipulator, gridConfig) call in init body
5. CHANGE case "terminal" to: return await gridTerminal.toggle()
6. REMOVE handleTerminal() method (lines 685-695)
7. REMOVE findTerminalWindow() method (lines 697-726)
8. REMOVE toggleTerminalWindow() method (lines 728-781)
9. REMOVE launchTerminal() method (lines 783-831)
```

### main.swift (MODIFY)

```
Changes:
1. After existing Grid* instantiation (line 158), ADD:
   let gridTerminal = GridTerminal()

2. In GridCommandRouter constructor call (line 167), ADD:
   gridTerminal: gridTerminal parameter
```

## Design Notes
- GridTerminal follows the exact same pattern as GridFocus: empty init, setup() with weak deps, single public method
- The `gridConfig` dependency is included in setup() even though current code doesn't use it -- future phases will need it for terminal sizing/positioning config
- All private methods move verbatim from router to GridTerminal -- no logic changes
- The `cachedTerminalWindowID` state moves from router to GridTerminal as an instance variable

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (Grid* pattern consistency, deep module check)
- [x] Ready for implementation
