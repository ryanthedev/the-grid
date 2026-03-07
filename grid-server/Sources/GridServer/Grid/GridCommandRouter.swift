import Foundation
import CoreGraphics

// MARK: - Command Result

struct CommandResult: Sendable {
    let success: Bool
    let message: String

    static func ok(_ message: String = "") -> CommandResult {
        CommandResult(success: true, message: message)
    }

    static func error(_ message: String) -> CommandResult {
        CommandResult(success: false, message: message)
    }
}

// MARK: - Parsed Command

struct ParsedCommand {
    let domain: String
    let action: String
    let args: [String]
    let flags: Set<String>
    let flagValues: [String: String]
}

// MARK: - GridCommandRouter

class GridCommandRouter {

    private let gridFocus: GridFocus
    private let gridCellOps: GridCellOps
    private let gridWindowMove: GridWindowMove
    private let gridApply: GridApply
    private let gridResize: GridResize
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager
    private let windowManipulator: WindowManipulator
    private let gridReconciler: GridReconciler
    private let simpleBorderManager: SimpleBorderManager
    private let gridRecorder: GridRecorder

    init(
        gridFocus: GridFocus,
        gridCellOps: GridCellOps,
        gridWindowMove: GridWindowMove,
        gridApply: GridApply,
        gridResize: GridResize,
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager,
        windowManipulator: WindowManipulator,
        gridReconciler: GridReconciler,
        simpleBorderManager: SimpleBorderManager,
        gridRecorder: GridRecorder
    ) {
        self.gridFocus = gridFocus
        self.gridCellOps = gridCellOps
        self.gridWindowMove = gridWindowMove
        self.gridApply = gridApply
        self.gridResize = gridResize
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
        self.windowManipulator = windowManipulator
        self.gridReconciler = gridReconciler
        self.simpleBorderManager = simpleBorderManager
        self.gridRecorder = gridRecorder

        // Wire feature modules via their setup() methods
        gridFocus.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager,
            windowManipulator: windowManipulator
        )

        gridCellOps.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager,
            gridFocus: gridFocus
        )

        gridWindowMove.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager,
            gridFocus: gridFocus,
            windowManipulator: windowManipulator,
            gridReconciler: gridReconciler
        )

        gridApply.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager,
            windowManipulator: windowManipulator,
            gridReconciler: gridReconciler,
            simpleBorderManager: simpleBorderManager,
            gridFocus: gridFocus
        )

        gridResize.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            gridApply: gridApply,
            gridFocus: gridFocus,
            stateManager: stateManager
        )

        // Circular dependency resolution
        gridCellOps.setApply(gridApply)
        gridWindowMove.setApply(gridApply)

        jlog("router.init")
    }

    // ============================================================
    // PUBLIC: dispatch -- single entry point
    // ============================================================

    func dispatch(_ command: String) async -> CommandResult {
        // 1. Parse the command string
        guard let parsed = parse(command) else {
            return .error("invalid command format")
        }

        // 2. Log the dispatch
        jlog("cmd.dispatch", data: ["domain": parsed.domain, "action": parsed.action])

        // 3. Switch on domain
        do {
            switch parsed.domain {
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
                return try await handleRecord(parsed)
            default:
                return .error("unknown domain: \(parsed.domain)")
            }
        } catch {
            jlog("cmd.err", data: ["domain": parsed.domain, "action": parsed.action, "err": "\(error)"])
            return .error(error.localizedDescription)
        }
    }

    // ============================================================
    // PRIVATE: parse -- split command string into ParsedCommand
    // ============================================================

    private func parse(_ command: String) -> ParsedCommand? {
        // Strip leading "@" and whitespace
        var stripped = command
        if stripped.hasPrefix("@") {
            stripped = String(stripped.dropFirst())
        }
        stripped = stripped.trimmingCharacters(in: .whitespaces)

        // Split on whitespace
        let tokens = stripped.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // Need at least a domain
        guard !tokens.isEmpty else { return nil }

        let domain = tokens[0]
        let action = tokens.count > 1 ? tokens[1] : ""

        // Remaining tokens: separate into args and flags
        var args: [String] = []
        var flags: Set<String> = []
        var flagValues: [String: String] = [:]

        var i = 2
        while i < tokens.count {
            if tokens[i].hasPrefix("--") {
                let flagName = String(tokens[i].dropFirst(2))
                // Check if next token is a value (not a flag)
                if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                    flagValues[flagName] = tokens[i + 1]
                    i += 2
                } else {
                    flags.insert(flagName)
                    i += 1
                }
            } else {
                args.append(tokens[i])
                i += 1
            }
        }

        return ParsedCommand(
            domain: domain,
            action: action,
            args: args,
            flags: flags,
            flagValues: flagValues
        )
    }

    // ============================================================
    // PRIVATE: resolveActiveSpaceID
    // ============================================================

    private func resolveActiveSpaceID() async -> String? {
        let wmState = await stateManager.getState()
        return gridFocus.findActiveSpaceID(wmState)
    }

    // ============================================================
    // PRIVATE: handleFocus
    // ============================================================

    private func handleFocus(_ cmd: ParsedCommand) async throws -> CommandResult {
        switch cmd.action {
        case "left", "right", "up", "down":
            guard let direction = GridDirection(from: cmd.action) else {
                return .error("invalid direction: \(cmd.action)")
            }
            let opts = MoveFocusOpts(
                wrapAround: cmd.flags.contains("wrap"),
                extend: cmd.flags.contains("extend"),
                warpMouse: cmd.flags.contains("mouse")
            )
            let windowID = try await gridFocus.moveFocus(direction: direction, opts: opts)
            return .ok("focused window \(windowID)")

        case "next":
            let windowID = try await gridFocus.cycleFocus(forward: true)
            return .ok("focused window \(windowID)")

        case "prev":
            let windowID = try await gridFocus.cycleFocus(forward: false)
            return .ok("focused window \(windowID)")

        case "cell":
            // @focus cell <cellID> [--space <spaceID>]
            guard let cellID = cmd.args.first else {
                return .error("missing cell ID")
            }
            let spaceID: String
            if let explicit = cmd.flagValues["space"] {
                spaceID = explicit
            } else {
                spaceID = await resolveActiveSpaceID() ?? ""
            }
            guard !spaceID.isEmpty else {
                return .error("no active space")
            }
            let windowID = try await gridFocus.focusCell(spaceID: spaceID, cellID: cellID)
            return .ok("focused cell \(cellID) window \(windowID)")

        default:
            return .error("unknown focus action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handleLayout
    // ============================================================

    private func handleLayout(_ cmd: ParsedCommand) async throws -> CommandResult {
        switch cmd.action {
        case "apply":
            // @layout apply <layoutID> [--strategy position|preserve|autoflow]
            guard let layoutID = cmd.args.first else {
                return .error("missing layout ID")
            }
            guard let spaceID = await resolveActiveSpaceID() else {
                return .error("no active space")
            }
            let strategyStr = cmd.flagValues["strategy"] ?? "position"
            let strategy = parseStrategy(strategyStr)
            try await gridApply.applyLayout(spaceID: spaceID, layoutID: layoutID, strategy: strategy)
            return .ok("applied layout \(layoutID)")

        case "cycle":
            // @layout cycle
            guard let spaceID = await resolveActiveSpaceID() else {
                return .error("no active space")
            }
            let layoutIDs = await MainActor.run { gridConfig.getLayoutIDs() }
            let newLayoutID = await gridState.cycleLayout(spaceID: spaceID, availableLayouts: layoutIDs)
            try await gridApply.applyLayout(spaceID: spaceID, layoutID: newLayoutID)
            return .ok("cycled to layout \(newLayoutID)")

        case "previous":
            // @layout previous
            guard let spaceID = await resolveActiveSpaceID() else {
                return .error("no active space")
            }
            let layoutIDs = await MainActor.run { gridConfig.getLayoutIDs() }
            let newLayoutID = await gridState.previousLayout(spaceID: spaceID, availableLayouts: layoutIDs)
            try await gridApply.applyLayout(spaceID: spaceID, layoutID: newLayoutID)
            return .ok("switched to layout \(newLayoutID)")

        case "refresh":
            // @layout refresh [--display <uuid>]
            let displayFilter = cmd.flagValues["display"]
            let errors = await gridApply.refreshAllDisplays(displayFilter: displayFilter)
            if errors.isEmpty {
                return .ok("refreshed all displays")
            } else {
                return .error("refresh had \(errors.count) errors")
            }

        default:
            return .error("unknown layout action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handleCell
    // ============================================================

    private func handleCell(_ cmd: ParsedCommand) async throws -> CommandResult {
        switch cmd.action {
        case "send":
            // @cell send <direction>
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else {
                return .error("missing or invalid direction")
            }
            try await gridCellOps.sendWindow(direction: direction)
            return .ok("sent window \(dirStr)")

        case "swap":
            // @cell swap <direction>
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else {
                return .error("missing or invalid direction")
            }
            try await gridCellOps.swapWindow(direction: direction)
            return .ok("swapped window \(dirStr)")

        case "mode":
            // @cell mode [vertical|horizontal|tabs]
            let targetMode: GridStackMode?
            if let modeStr = cmd.args.first {
                targetMode = GridStackMode(rawValue: modeStr)
                if targetMode == nil {
                    return .error("invalid mode: \(modeStr)")
                }
            } else {
                // No arg = cycle
                targetMode = nil
            }
            let result = try await gridCellOps.setMode(targetMode: targetMode)
            return .ok("cell \(result.cellID) mode \(result.newMode.rawValue)")

        default:
            return .error("unknown cell action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handleWindow
    // ============================================================

    private func handleWindow(_ cmd: ParsedCommand) async throws -> CommandResult {
        switch cmd.action {
        case "move":
            // @window move <direction> [--extend] [--wrap]
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else {
                return .error("missing or invalid direction")
            }
            let opts = GridMoveOpts(
                wrapAround: cmd.flags.contains("wrap"),
                extend: cmd.flags.contains("extend")
            )
            let result = try await gridWindowMove.moveWindow(direction: direction, opts: opts)
            return .ok("moved window \(result.windowID) to \(result.targetCell)")

        default:
            return .error("unknown window action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handleResize
    // ============================================================

    private func handleResize(_ cmd: ParsedCommand) async throws -> CommandResult {
        guard let spaceID = await resolveActiveSpaceID() else {
            return .error("no active space")
        }

        switch cmd.action {
        case "grow":
            // @resize grow [amount] [--cell] [--direction left/right/up/down]
            let amount = Double(cmd.args.first ?? "0.1") ?? 0.1
            if cmd.flags.contains("cell") {
                let dirStr = cmd.flagValues["direction"] ?? "right"
                guard let direction = GridDirection(from: dirStr) else {
                    return .error("invalid direction")
                }
                try await gridResize.adjustCellBoundary(spaceID: spaceID, direction: direction, delta: amount)
            } else {
                try await gridResize.adjustFocusedSplit(spaceID: spaceID, delta: amount)
            }
            return .ok("grew by \(amount)")

        case "shrink":
            // Same as grow but negative delta
            let amount = Double(cmd.args.first ?? "0.1") ?? 0.1
            if cmd.flags.contains("cell") {
                let dirStr = cmd.flagValues["direction"] ?? "right"
                guard let direction = GridDirection(from: dirStr) else {
                    return .error("invalid direction")
                }
                try await gridResize.adjustCellBoundary(spaceID: spaceID, direction: direction, delta: -amount)
            } else {
                try await gridResize.adjustFocusedSplit(spaceID: spaceID, delta: -amount)
            }
            return .ok("shrunk by \(amount)")

        case "reset":
            // @resize reset [--cell] [--all]
            if cmd.flags.contains("cell") {
                try await gridResize.resetCellRatios(spaceID: spaceID)
            } else {
                let allCells = cmd.flags.contains("all")
                try await gridResize.resetSplits(spaceID: spaceID, allCells: allCells)
            }
            return .ok("reset splits")

        default:
            return .error("unknown resize action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handleMouse
    // ============================================================

    private func handleMouse(_ cmd: ParsedCommand) async throws -> CommandResult {
        switch cmd.action {
        case "center":
            // @mouse center -- warp to focused window center
            guard let spaceID = await resolveActiveSpaceID() else {
                return .error("no active space")
            }
            let focusedWid = await gridState.getFocusedWindow(spaceID: spaceID)
            guard focusedWid != 0 else {
                return .error("no focused window")
            }
            let wmState = await stateManager.getState()
            guard let windowState = wmState.windows[String(focusedWid)] else {
                return .error("window frame not found")
            }
            let frame = windowState.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            CGWarpMouseCursorPosition(center)
            return .ok("warped to window \(focusedWid)")

        case "warp":
            // @mouse warp <windowID>
            guard let widStr = cmd.args.first,
                  let windowID = UInt32(widStr) else {
                return .error("missing or invalid window ID")
            }
            let wmState = await stateManager.getState()
            guard let windowState = wmState.windows[String(windowID)] else {
                return .error("window \(windowID) frame not found")
            }
            let frame = windowState.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            CGWarpMouseCursorPosition(center)
            return .ok("warped to window \(windowID)")

        default:
            return .error("unknown mouse action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handlePick
    // ============================================================

    private func handlePick(_ cmd: ParsedCommand) async -> CommandResult {
        // @pick [show] -- show the picker
        await MainActor.run {
            PickerManager.shared.show()
        }
        return .ok("picker shown")
    }

    // ============================================================
    // PRIVATE: handleState
    // ============================================================

    private func handleState(_ cmd: ParsedCommand) async throws -> CommandResult {
        switch cmd.action {
        case "reset":
            // @state reset -- clear all grid state for active space
            guard let spaceID = await resolveActiveSpaceID() else {
                return .error("no active space")
            }
            await gridState.removeSpace(spaceID)
            return .ok("reset state for space \(spaceID)")

        default:
            return .error("unknown state action: \(cmd.action)")
        }
    }

    // ============================================================
    // PRIVATE: handleRecord
    // ============================================================

    private func handleRecord(_ cmd: ParsedCommand) async throws -> CommandResult {
        if cmd.action == "cancel" {
            await gridRecorder.cancel()
            return .ok("recording cancelled")
        }

        if cmd.action == "status" {
            let active = await gridRecorder.recording
            return .ok(active ? "recording" : "idle")
        }

        let target = parseRecordingTarget(action: cmd.action, args: cmd.args)

        var options = RecordingOptions()
        if let d = cmd.flagValues["duration"], let v = Int(d) {
            options.duration = v
        }
        if let f = cmd.flagValues["format"] {
            options.format = f
        }
        if let q = cmd.flagValues["quality"], let v = RecordingQuality(rawValue: q) {
            options.quality = v
        }
        if let f = cmd.flagValues["fps"], let v = Int(f) {
            options.fps = v
        }
        if let w = cmd.flagValues["width"], let v = Int(w) {
            options.width = v
        }
        if let c = cmd.flagValues["countdown"], let v = Int(c) {
            options.countdown = v
        }
        if let o = cmd.flagValues["output"] {
            options.output = o
        }
        if cmd.flags.contains("cursor") {
            options.cursor = true
        }
        if cmd.flags.contains("follow") {
            options.follow = true
        }
        if cmd.flags.contains("open") {
            options.open = true
        }

        let result = try await gridRecorder.record(target: target, options: options)
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return .ok(json)
    }

    private func parseRecordingTarget(action: String, args: [String]) -> RecordingTarget {
        let targetStr = args.first ?? "cell"
        let id = args.count > 1 ? args[1] : nil
        switch targetStr {
        case "cell":
            return .cell(id: id)
        case "window":
            return .window(id: id.flatMap { UInt32($0) })
        case "screen", "display":
            return .screen(index: id.flatMap { Int($0) })
        case "all":
            return .all
        default:
            return .cell(id: nil)
        }
    }

    // ============================================================
    // PRIVATE: parseStrategy helper
    // ============================================================

    private func parseStrategy(_ str: String) -> GridAssignmentStrategy {
        switch str {
        case "preserve": return .preserve
        case "autoflow": return .autoFlow
        case "pinned": return .pinned
        default: return .position
        }
    }
}
