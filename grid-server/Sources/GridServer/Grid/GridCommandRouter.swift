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
    private let gridNudge: GridNudge
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager
    private let windowManipulator: WindowManipulator
    private let gridReconciler: GridReconciler
    private let simpleBorderManager: SimpleBorderManager
    private let gridRecorder: GridRecorder
    private let gridTerminalManager: GridTerminalManager

    // Non-nil while a nudge session is active — owns the CGEventTap for that session
    private var nudgeKeyHandler: NudgeKeyHandler?

    // Suppression token held for the duration of a nudge session.
    // beginAction increments suppression, endAction decrements and syncs.
    private var nudgeActionToken: GridReconciler.ActionToken?

    // Short flag -> long flag mapping for BFD commands
    private static let shortFlagMap: [Character: String] = [
        "m": "mouse",
        "w": "wrap",
        "e": "extend",
    ]

    init(
        gridFocus: GridFocus,
        gridCellOps: GridCellOps,
        gridWindowMove: GridWindowMove,
        gridApply: GridApply,
        gridResize: GridResize,
        gridNudge: GridNudge,
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager,
        windowManipulator: WindowManipulator,
        gridReconciler: GridReconciler,
        simpleBorderManager: SimpleBorderManager,
        gridRecorder: GridRecorder,
        gridTerminalManager: GridTerminalManager
    ) {
        self.gridFocus = gridFocus
        self.gridCellOps = gridCellOps
        self.gridWindowMove = gridWindowMove
        self.gridApply = gridApply
        self.gridResize = gridResize
        self.gridNudge = gridNudge
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
        self.windowManipulator = windowManipulator
        self.gridReconciler = gridReconciler
        self.simpleBorderManager = simpleBorderManager
        self.gridRecorder = gridRecorder
        self.gridTerminalManager = gridTerminalManager

        // Wire feature modules via their setup() methods
        gridFocus.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager,
            windowManipulator: windowManipulator
        )
        gridFocus.setReconciler(gridReconciler)

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

        gridNudge.setup(
            gridState: gridState,
            stateManager: stateManager,
            windowManipulator: windowManipulator
        )

        // Circular dependency resolution
        gridCellOps.setApply(gridApply)
        gridWindowMove.setApply(gridApply)
        gridReconciler.setApply(gridApply)
        gridReconciler.setFocus(gridFocus)

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

        // 2. Wait for any in-progress wake validation to finish.
        // Fast path during normal operation: returns immediately (task is nil).
        // This ensures commands see post-migration, post-validation state.
        await gridReconciler.awaitWakeCompletion()

        // 3. Log the dispatch
        jlog("cmd.dispatch", data: ["domain": parsed.domain, "action": parsed.action])

        // 4. Switch on domain
        do {
            switch parsed.domain {
            case "focus":
                return try await gridReconciler.executeAction(label: "focus.\(parsed.action)") {
                    try await handleFocus(parsed)
                }
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
            case "terminal":
                return await gridTerminalManager.toggle()
            case "nudge":
                // Suppression managed via beginAction/endAction inside handleNudge --
                // enter starts the session, exit ends it. No executeAction wrapper here.
                return await handleNudge(parsed)
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
                // Check if next token is a value (not another flag)
                if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") && !tokens[i + 1].hasPrefix("-") {
                    flagValues[flagName] = tokens[i + 1]
                    i += 2
                } else {
                    flags.insert(flagName)
                    i += 1
                }
            } else if tokens[i].hasPrefix("-") && tokens[i].count > 1 && !tokens[i].hasPrefix("--") {
                // Short flags: -m -> mouse, -w -> wrap, -e -> extend
                let shortFlags = tokens[i].dropFirst()
                for ch in shortFlags {
                    let longName = Self.shortFlagMap[ch] ?? String(ch)
                    flags.insert(longName)
                }
                i += 1
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

    private func warpMouseToFocusedWindow() async {
        let wmState = await stateManager.getState()
        guard let spaceID = gridFocus.findActiveSpaceID(wmState) else { return }
        let focusedWid = await gridState.getFocusedWindow(spaceID: spaceID)
        guard focusedWid != 0,
              let windowState = wmState.windows[String(focusedWid)] else { return }
        let frame = windowState.frame
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
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
            if cmd.flags.contains("mouse") {
                await warpMouseToFocusedWindow()
            }
            return .ok("focused window \(windowID)")

        case "prev":
            let windowID = try await gridFocus.cycleFocus(forward: false)
            if cmd.flags.contains("mouse") {
                await warpMouseToFocusedWindow()
            }
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
            // @window move <direction> [--extend] [--wrap] [-m/--mouse]
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else {
                return .error("missing or invalid direction")
            }
            let opts = GridMoveOpts(
                wrapAround: cmd.flags.contains("wrap"),
                extend: cmd.flags.contains("extend"),
                warpMouse: cmd.flags.contains("mouse")
            )
            let result = try await gridWindowMove.moveWindow(direction: direction, opts: opts)
            return .ok("moved window \(result.windowID) to \(result.targetCell)")

        case "swap":
            // @window swap <direction> [-m/--mouse]
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else {
                return .error("missing or invalid direction")
            }
            try await gridCellOps.swapWindow(direction: direction)
            if cmd.flags.contains("mouse") {
                await warpMouseToFocusedWindow()
            }
            return .ok("swapped \(dirStr)")

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
        case "cell":
            // @resize cell <direction> [amount]
            guard let dirStr = cmd.args.first,
                  let direction = GridDirection(from: dirStr) else {
                return .error("missing or invalid direction")
            }
            let amount = Double(cmd.args.count > 1 ? cmd.args[1] : "0.05") ?? 0.05
            try await gridResize.adjustCellBoundary(spaceID: spaceID, direction: direction, delta: amount)
            return .ok("resized cell \(dirStr) by \(amount)")

        case "grow":
            // @resize grow [amount]
            let amount = Double(cmd.args.first ?? "0.1") ?? 0.1
            try await gridResize.adjustFocusedSplit(spaceID: spaceID, delta: amount)
            return .ok("grew by \(amount)")

        case "shrink":
            // @resize shrink [amount]
            let amount = Double(cmd.args.first ?? "0.1") ?? 0.1
            try await gridResize.adjustFocusedSplit(spaceID: spaceID, delta: -amount)
            return .ok("shrunk by \(amount)")

        case "reset":
            // @resize reset [--cells] [--all]
            if cmd.flags.contains("cells") || cmd.flags.contains("cell") {
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
        // 1. Capture focus state BEFORE showing picker (picker steals focus)
        let spaceID = await resolveActiveSpaceID()
        var cellID: String? = nil
        if let spaceID {
            cellID = await gridState.getFocusedCell(spaceID: spaceID)
        }

        // 2. Set onLaunch callback if we have valid capture
        if let spaceID, let cellID, !cellID.isEmpty {
            await MainActor.run { [weak self] in
                PickerManager.shared.onLaunch = { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .openApp, .openDir, .openChromeProfile:
                        self.gridReconciler.setPendingLaunchTarget(
                            PendingLaunchTarget(
                                spaceID: spaceID,
                                cellID: cellID,
                                createdAt: CFAbsoluteTimeGetCurrent()
                            )
                        )
                    default:
                        break
                    }
                }
            }
        }

        // 3. Save focused window for cancel restoration, then show the picker
        let state = await stateManager.getState()
        let focusedWID = state.metadata.focusedWindowID
        let focusedPID: pid_t? = focusedWID.flatMap { state.windows[String($0)]?.pid }
        await MainActor.run {
            if let wid = focusedWID, let pid = focusedPID {
                PickerManager.shared.savePreviousWindow(windowID: wid, pid: pid)
            }
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

        // "stop" needs no target or options — stop whatever is running.
        if cmd.action == "stop" {
            do {
                let result = try await gridRecorder.stop()
                let data = try JSONEncoder().encode(result)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                return .ok(json)
            } catch {
                return .error(error.localizedDescription)
            }
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

        // "toggle" needs target+options on start; actor ignores them on stop.
        if cmd.action == "toggle" {
            do {
                let result = try await gridRecorder.toggle(target: target, options: options)
                if let result {
                    // Recording just stopped — encode full result.
                    let data = try JSONEncoder().encode(result)
                    let json = String(data: data, encoding: .utf8) ?? "{}"
                    return .ok(json)
                } else {
                    // Recording just started — no result yet.
                    return .ok("{\"action\":\"started\"}")
                }
            } catch {
                return .error(error.localizedDescription)
            }
        }

        // "start" and bare target actions: branch on duration.
        // nil duration → startRecording (background, returns immediately).
        // non-nil duration → record (blocks until done, returns result).
        if options.duration == nil {
            do {
                try await gridRecorder.startRecording(target: target, options: options)
                return .ok("{\"action\":\"started\"}")
            } catch {
                return .error(error.localizedDescription)
            }
        } else {
            do {
                let result = try await gridRecorder.record(target: target, options: options)
                let data = try JSONEncoder().encode(result)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                return .ok(json)
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }

    // ============================================================
    // PRIVATE: handleNudge
    // ============================================================

    private func handleNudge(_ cmd: ParsedCommand) async -> CommandResult {
        switch cmd.action {

        case "enter":
            // Idempotent: if a session is already active, do nothing
            if nudgeKeyHandler != nil {
                return .ok("already in nudge mode")
            }

            // Resolve spaceID once -- NudgeKeyHandler.onNudge fires synchronously on the
            // main thread, so spaceID must be captured here (not fetched per-keypress)
            guard let spaceID = await resolveActiveSpaceID() else {
                return .error("no active space")
            }

            // Begin a long-lived suppression session for the nudge duration
            let token = gridReconciler.beginAction(label: "nudge")

            // Suspend BFD event tap so nudge keys are not also processed as hotkeys
            BFDManager.shared?.suspendEventTap()

            // Wire the key handler callback
            let handler = NudgeKeyHandler()
            let borderManager = self.simpleBorderManager
            handler.onNudge = { [weak self] action in
                guard let self else { return }
                switch action {
                case .move(let direction):
                    // onNudge fires on main thread; bridge to async actor context
                    Task {
                        if let (wid, frame) = try? await self.gridNudge.move(spaceID: spaceID, direction: direction) {
                            borderManager.handleWindowMoved(windowID: wid, newFrame: frame)
                        }
                    }
                case .resize(let direction):
                    Task {
                        if let (wid, frame) = try? await self.gridNudge.resize(spaceID: spaceID, direction: direction) {
                            borderManager.handleWindowMoved(windowID: wid, newFrame: frame)
                        }
                    }
                case .exit:
                    // Dispatch back through the router to avoid mutating nudgeKeyHandler
                    // from within its own callback's call stack
                    Task {
                        _ = await self.dispatch("@nudge exit")
                    }
                }
            }

            // Install the event tap -- may fail if Accessibility permission is absent
            guard handler.start() else {
                BFDManager.shared?.resumeEventTap()
                gridReconciler.endAction(token, syncBorders: false)
                return .error("nudge tap failed (accessibility permission?)")
            }

            nudgeKeyHandler = handler
            nudgeActionToken = token

            // Activate amber border feedback on the active border
            await MainActor.run {
                simpleBorderManager.setNudgeMode(active: true)
            }

            jlog("nudge.enter", data: ["space": spaceID])
            return .ok("nudge mode entered")

        case "exit":
            // Idempotent: if not in nudge mode, no-op
            guard nudgeKeyHandler != nil else {
                return .ok("not in nudge mode")
            }

            // Tear down key handler first to stop any further callbacks
            nudgeKeyHandler?.stop()
            nudgeKeyHandler = nil

            // Resume BFD event tap
            BFDManager.shared?.resumeEventTap()

            // Restore normal active border style
            await MainActor.run {
                simpleBorderManager.setNudgeMode(active: false)
            }

            // End the suppression session -- syncs borders to final window positions
            if let token = nudgeActionToken {
                gridReconciler.endAction(token, syncBorders: true)
                nudgeActionToken = nil
            }

            jlog("nudge.exit")
            return .ok("nudge mode exited")

        default:
            return .error("unknown nudge action: \(cmd.action)")
        }
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
