# Pseudocode: Phase 8 - BFD @ Command Router

## Design: GridCommandRouter

### Approaches Considered

1. **Single dispatch function with switch** -- One `dispatch(_ command: String) async` method that parses and switches on domain+action in a flat switch statement. All feature modules held as stored properties.

2. **Domain handler protocol + registry** -- Define a `DomainHandler` protocol with `func handle(action:args:flags:)`. Register one handler per domain. Router looks up handler by domain string, delegates.

3. **Enum-based parsed command** -- Parse string into a `GridCommand` enum (e.g., `.focus(.move(.left, opts))`, `.layout(.apply("dev"))`). Router dispatches on enum. Strongly typed, but large enum surface.

### Comparison

| Criterion | A: Flat switch | B: Protocol registry | C: Enum command |
|-----------|---------------|---------------------|-----------------|
| Interface simplicity | 1 method | 1 method + N handlers | 1 method + enum |
| Information hiding | High (all routing internal) | Medium (handlers exposed) | High |
| Caller ease of use | Simple string in | Simple string in | Requires enum construction |
| Extensibility | Add case to switch | Register new handler | Add enum case |
| Code volume | Moderate | High (boilerplate) | High (enum + parsing) |
| Error handling | Straightforward | Distributed across handlers | Straightforward |

### Choice: A (Flat switch)

Rationale: The command set is fixed and known at compile time. A flat switch is the simplest approach with all routing logic in one place. The protocol approach adds abstraction without benefit since we're not dynamically loading handlers. The enum approach is over-engineered for fire-and-forget hotkey dispatch. The switch can be cleanly organized into MARK sections by domain.

### Depth Check
- Interface methods: 1 (`dispatch`)
- Hidden details: command parsing, space ID resolution, feature module wiring, flag extraction, error handling
- Common case complexity: Simple -- BFD passes "@focus left" string, router does everything

## Files to Create/Modify

1. **CREATE** `Grid/GridCommandRouter.swift` -- router class
2. **MODIFY** `BFD/BFDManager.swift` -- replace handleInternalCommand switch body
3. **MODIFY** `main.swift` -- instantiate feature modules, create router, pass to BFDManager

## Pseudocode

### Grid/GridCommandRouter.swift

```
// CommandResult: success/error wrapper for logging
struct CommandResult
    success: Bool
    message: String (optional, for logging only)

// ParsedCommand: intermediate parsed form
struct ParsedCommand
    domain: String       -- "focus", "layout", etc.
    action: String       -- "left", "apply", etc.
    args: [String]       -- positional args after action
    flags: Set<String>   -- "--mouse", "--extend", etc.
    flagValues: [String: String]  -- "--amount 0.1" parsed pairs

// GridCommandRouter: parses @ commands, dispatches to feature modules
class GridCommandRouter

    // Dependencies: all feature modules + state/config
    stored properties (not weak -- router owns the lifecycle):
        gridFocus: GridFocus
        gridCellOps: GridCellOps
        gridWindowMove: GridWindowMove
        gridApply: GridApply
        gridResize: GridResize
        gridState: GridState
        gridConfig: GridConfig (MainActor)
        stateManager: StateManager
        windowManipulator: WindowManipulator
        gridReconciler: GridReconciler

    init(dependencies...)
        Store all dependencies
        Wire feature modules via their setup() methods
        Handle circular deps: gridCellOps.setApply(gridApply), gridWindowMove.setApply(gridApply)

    // ============================================================
    // PUBLIC: dispatch -- single entry point
    // ============================================================

    func dispatch(_ command: String) async -> CommandResult
        // 1. Parse the command string
        let parsed = parse(command)
        if parsed is nil
            return error("invalid command format")

        // 2. Log the dispatch
        log "cmd.dispatch" with domain, action

        // 3. Resolve active space ID (most commands need it)
        //    Lazy -- only resolved when needed inside handlers

        // 4. Switch on domain
        do
            switch parsed.domain

            case "focus":
                return try await handleFocus(parsed)

            case "layout":
                return try await handleLayout(parsed)

            case "cell":
                return try await handleCell(parsed)

            case "window":
                return try await handleWindow(parsed)

            case "resize":
                return try await handleResize(parsed)

            case "mouse":
                return try await handleMouse(parsed)

            case "pick":
                return await handlePick(parsed)

            case "state":
                return try await handleState(parsed)

            case "record":
                return error("record not yet implemented")

            default:
                return error("unknown domain: \(parsed.domain)")

        catch
            log error
            return error(error description)

    // ============================================================
    // PRIVATE: parse -- split command string into ParsedCommand
    // ============================================================

    private func parse(_ command: String) -> ParsedCommand?
        // Strip leading "@"
        let stripped = command without leading "@" and whitespace

        // Split on whitespace
        let tokens = stripped split by whitespace

        // Need at least a domain
        if tokens is empty, return nil

        // First token is domain
        let domain = tokens[0]

        // Second token (if present) is action
        let action = tokens.count > 1 ? tokens[1] : ""

        // Remaining tokens: separate into args and flags
        var args: [String] = []
        var flags: Set<String> = []
        var flagValues: [String: String] = [:]

        for i in 2..<tokens.count
            if tokens[i] starts with "--"
                let flagName = tokens[i] without "--"
                // Check if next token is a value (not a flag)
                if i+1 < tokens.count AND tokens[i+1] does NOT start with "--"
                    flagValues[flagName] = tokens[i+1]
                    skip next token
                else
                    flags.insert(flagName)
            else
                args.append(tokens[i])

        return ParsedCommand(domain, action, args, flags, flagValues)

    // ============================================================
    // PRIVATE: resolveActiveSpaceID -- helper used by most handlers
    // ============================================================

    private func resolveActiveSpaceID() async -> String?
        let wmState = await stateManager.getState()
        return gridFocus.findActiveSpaceID(wmState)

    // ============================================================
    // PRIVATE: handleFocus
    // ============================================================

    private func handleFocus(_ cmd: ParsedCommand) async throws -> CommandResult
        switch cmd.action

        case "left", "right", "up", "down":
            // Parse direction
            let direction = GridDirection(from: cmd.action)!
            // Parse opts from flags
            let opts = MoveFocusOpts(
                wrapAround: cmd.flags.contains("wrap"),
                extend: cmd.flags.contains("extend"),
                warpMouse: cmd.flags.contains("mouse")
            )
            let windowID = try await gridFocus.moveFocus(direction: direction, opts: opts)
            return success("focused window \(windowID)")

        case "next":
            let windowID = try await gridFocus.cycleFocus(forward: true)
            return success("focused window \(windowID)")

        case "prev":
            let windowID = try await gridFocus.cycleFocus(forward: false)
            return success("focused window \(windowID)")

        case "cell":
            // @focus cell <cellID> [--space <spaceID>]
            guard let cellID = cmd.args.first else
                return error("missing cell ID")
            let spaceID = cmd.flagValues["space"] ?? (resolveActiveSpaceID() await) ?? ""
            guard !spaceID.isEmpty else
                return error("no active space")
            let windowID = try await gridFocus.focusCell(spaceID: spaceID, cellID: cellID)
            return success("focused cell \(cellID) window \(windowID)")

        default:
            return error("unknown focus action: \(cmd.action)")

    // ============================================================
    // PRIVATE: handleLayout
    // ============================================================

    private func handleLayout(_ cmd: ParsedCommand) async throws -> CommandResult
        switch cmd.action

        case "apply":
            // @layout apply <layoutID> [--strategy position|preserve|autoflow]
            guard let layoutID = cmd.args.first else
                return error("missing layout ID")
            let spaceID = await resolveActiveSpaceID()
            guard let spaceID else
                return error("no active space")
            let strategyStr = cmd.flagValues["strategy"] ?? "position"
            let strategy = parseStrategy(strategyStr)
            try await gridApply.applyLayout(spaceID: spaceID, layoutID: layoutID, strategy: strategy)
            return success("applied layout \(layoutID)")

        case "cycle":
            // @layout cycle
            let spaceID = await resolveActiveSpaceID()
            guard let spaceID else
                return error("no active space")
            let layoutIDs = await MainActor.run { gridConfig.getLayoutIDs() }
            let newLayoutID = await gridState.cycleLayout(spaceID: spaceID, availableLayouts: layoutIDs)
            try await gridApply.applyLayout(spaceID: spaceID, layoutID: newLayoutID)
            return success("cycled to layout \(newLayoutID)")

        case "previous":
            // @layout previous
            let spaceID = await resolveActiveSpaceID()
            guard let spaceID else
                return error("no active space")
            let layoutIDs = await MainActor.run { gridConfig.getLayoutIDs() }
            let newLayoutID = await gridState.previousLayout(spaceID: spaceID, availableLayouts: layoutIDs)
            try await gridApply.applyLayout(spaceID: spaceID, layoutID: newLayoutID)
            return success("switched to layout \(newLayoutID)")

        case "refresh":
            // @layout refresh [--display <uuid>]
            let displayFilter = cmd.flagValues["display"]
            let errors = await gridApply.refreshAllDisplays(displayFilter: displayFilter)
            if errors.isEmpty
                return success("refreshed all displays")
            else
                return error("refresh had \(errors.count) errors")

        default:
            return error("unknown layout action: \(cmd.action)")

    // ============================================================
    // PRIVATE: handleCell
    // ============================================================

    private func handleCell(_ cmd: ParsedCommand) async throws -> CommandResult
        switch cmd.action

        case "send":
            // @cell send <direction>
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else
                return error("missing or invalid direction")
            try await gridCellOps.sendWindow(direction: direction)
            return success("sent window \(direction.rawValue)")

        case "swap":
            // @cell swap <direction>
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else
                return error("missing or invalid direction")
            try await gridCellOps.swapWindow(direction: direction)
            return success("swapped window \(direction.rawValue)")

        case "mode":
            // @cell mode [vertical|horizontal|tabs]
            // No arg = cycle
            let targetMode: GridStackMode?
            if let modeStr = cmd.args.first
                targetMode = GridStackMode(rawValue: modeStr)
                if targetMode is nil
                    return error("invalid mode: \(modeStr)")
            else
                targetMode = nil  // cycle
            let result = try await gridCellOps.setMode(targetMode: targetMode)
            return success("cell \(result.cellID) mode \(result.newMode.rawValue)")

        default:
            return error("unknown cell action: \(cmd.action)")

    // ============================================================
    // PRIVATE: handleWindow
    // ============================================================

    private func handleWindow(_ cmd: ParsedCommand) async throws -> CommandResult
        switch cmd.action

        case "move":
            // @window move <direction> [--extend] [--wrap]
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else
                return error("missing or invalid direction")
            let opts = GridMoveOpts(
                wrapAround: cmd.flags.contains("wrap"),
                extend: cmd.flags.contains("extend")
            )
            let result = try await gridWindowMove.moveWindow(direction: direction, opts: opts)
            return success("moved window \(result.windowID) to \(result.targetCell)")

        default:
            return error("unknown window action: \(cmd.action)")

    // ============================================================
    // PRIVATE: handleResize
    // ============================================================

    private func handleResize(_ cmd: ParsedCommand) async throws -> CommandResult
        let spaceID = await resolveActiveSpaceID()
        guard let spaceID else
            return error("no active space")

        switch cmd.action

        case "grow":
            // @resize grow [amount] [--cell] [--direction left/right/up/down]
            let amount = Double(cmd.args.first ?? "0.1") ?? 0.1
            if cmd.flags.contains("cell")
                // Cell boundary resize
                let dirStr = cmd.flagValues["direction"] ?? "right"
                guard let direction = GridDirection(from: dirStr) else
                    return error("invalid direction")
                try await gridResize.adjustCellBoundary(spaceID: spaceID, direction: direction, delta: amount)
            else
                // Split resize within cell
                try await gridResize.adjustFocusedSplit(spaceID: spaceID, delta: amount)
            return success("grew by \(amount)")

        case "shrink":
            // Same as grow but negative delta
            let amount = Double(cmd.args.first ?? "0.1") ?? 0.1
            if cmd.flags.contains("cell")
                let dirStr = cmd.flagValues["direction"] ?? "right"
                guard let direction = GridDirection(from: dirStr) else
                    return error("invalid direction")
                try await gridResize.adjustCellBoundary(spaceID: spaceID, direction: direction, delta: -amount)
            else
                try await gridResize.adjustFocusedSplit(spaceID: spaceID, delta: -amount)
            return success("shrunk by \(amount)")

        case "reset":
            // @resize reset [--cell] [--all]
            if cmd.flags.contains("cell")
                try await gridResize.resetCellRatios(spaceID: spaceID)
            else
                let allCells = cmd.flags.contains("all")
                try await gridResize.resetSplits(spaceID: spaceID, allCells: allCells)
            return success("reset splits")

        default:
            return error("unknown resize action: \(cmd.action)")

    // ============================================================
    // PRIVATE: handleMouse
    // ============================================================

    private func handleMouse(_ cmd: ParsedCommand) async throws -> CommandResult
        switch cmd.action

        case "center":
            // @mouse center -- warp to focused window center
            let spaceID = await resolveActiveSpaceID()
            guard let spaceID else
                return error("no active space")
            let wmState = await stateManager.getState()
            let focusedWid = await gridState.getFocusedWindow(spaceID: spaceID)
            guard focusedWid != 0 else
                return error("no focused window")
            // Look up window frame from StateManager
            guard let windowState = wmState.windows[String(focusedWid)],
                  let frame = windowState.frame else
                return error("window frame not found")
            let center = CGPoint(x: frame.midX, y: frame.midY)
            CGWarpMouseCursorPosition(center)
            return success("warped to window \(focusedWid)")

        case "warp":
            // @mouse warp <windowID>
            guard let widStr = cmd.args.first,
                  let windowID = UInt32(widStr) else
                return error("missing or invalid window ID")
            let wmState = await stateManager.getState()
            guard let windowState = wmState.windows[String(windowID)],
                  let frame = windowState.frame else
                return error("window \(windowID) frame not found")
            let center = CGPoint(x: frame.midX, y: frame.midY)
            CGWarpMouseCursorPosition(center)
            return success("warped to window \(windowID)")

        default:
            return error("unknown mouse action: \(cmd.action)")

    // ============================================================
    // PRIVATE: handlePick
    // ============================================================

    private func handlePick(_ cmd: ParsedCommand) async -> CommandResult
        // @pick [show] -- show the picker
        await MainActor.run {
            PickerManager.shared.show()
        }
        return success("picker shown")

    // ============================================================
    // PRIVATE: handleState
    // ============================================================

    private func handleState(_ cmd: ParsedCommand) async throws -> CommandResult
        switch cmd.action

        case "reset":
            // @state reset -- clear all grid state for active space
            let spaceID = await resolveActiveSpaceID()
            guard let spaceID else
                return error("no active space")
            await gridState.resetSpace(spaceID)
            return success("reset state for space \(spaceID)")

        default:
            return error("unknown state action: \(cmd.action)")

    // ============================================================
    // PRIVATE: parseStrategy helper
    // ============================================================

    private func parseStrategy(_ str: String) -> GridAssignmentStrategy
        switch str
        case "preserve": return .preserve
        case "autoflow": return .autoFlow
        case "pinned": return .pinned
        default: return .position
```

### BFD/BFDManager.swift modifications

```
class BFDManager
    // ADD: stored reference to command router
    private var commandRouter: GridCommandRouter?

    // ADD: public setter (called from main.swift after router is created)
    func setCommandRouter(_ router: GridCommandRouter)
        self.commandRouter = router

    // MODIFY: handleInternalCommand -- replace entire switch body
    private func handleInternalCommand(_ command: String, hotkey: String)
        log "bfd.internal" with cmd and hotkey

        // If router is set, dispatch through it
        if let router = commandRouter
            Task {
                let result = await router.dispatch(command)
                if !result.success
                    log "cmd.err" with command and result.message
            }
            return

        // Fallback: legacy handling for @pick (in case router not yet ready)
        if command == "@pick"
            DispatchQueue.main.async { PickerManager.shared.show() }
        else
            log unknown command error
```

### main.swift modifications

```
// After gridReconciler.setup() block, add:

// Initialize Grid feature modules + command router
let gridFocus = GridFocus()
let gridCellOps = GridCellOps()
let gridWindowMove = GridWindowMove()
let gridApply = GridApply()
let gridResize = GridResize()

let commandRouter = GridCommandRouter(
    gridFocus: gridFocus,
    gridCellOps: gridCellOps,
    gridWindowMove: gridWindowMove,
    gridApply: gridApply,
    gridResize: gridResize,
    gridState: gridState,
    gridConfig: gridConfig,
    stateManager: StateManager.shared,
    windowManipulator: WindowManipulator.shared,
    gridReconciler: gridReconciler,
    simpleBorderManager: simpleBorderManager
)

bfdManager.setCommandRouter(commandRouter)
```

## Design Notes

1. **Single dispatch method** -- The router exposes exactly one public method: `dispatch(_ command: String) async -> CommandResult`. This is a deep module: simple interface hiding all parsing, routing, space resolution, and feature module coordination.

2. **Fire-and-forget from BFD** -- BFDManager wraps dispatch in `Task { }`. Errors are logged but not returned to the hotkey handler. This matches the existing `@pick` pattern.

3. **Router owns feature module lifecycle** -- The router holds strong references to feature modules. This is intentional: the router IS the owner. main.swift creates the router and passes it to BFDManager.

4. **Space ID resolution** -- Most commands need the active space. Rather than requiring callers to pass it, the router resolves it internally via `GridFocus.findActiveSpaceID()`. This is a key piece of information hiding.

5. **Flag parsing** -- Simple whitespace split with `--flag` and `--flag value` support. No shell quoting needed since BFD commands are predefined strings, not user input.

6. **Pick domain preserved** -- `@pick` routes through the router now, absorbing the existing hardcoded case. The legacy fallback in BFDManager handles the case where the router is not yet wired (startup race).

7. **Record placeholder** -- Returns error "not yet implemented" until Phase 11.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (flat switch chosen over protocol registry and enum command)
- [x] Ready for implementation
