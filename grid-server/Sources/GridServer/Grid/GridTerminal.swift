import Foundation
import CoreGraphics

// Codable struct for persisting a terminal window frame
struct TerminalFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

class GridTerminal {

    // Dependencies (weak references, set via setup)
    private weak var stateManager: StateManager?
    private weak var windowManipulator: WindowManipulator?
    private weak var gridConfig: GridConfig?

    // Cached terminal window ID to avoid full-scan on every toggle
    private var cachedTerminalWindowID: UInt32? = nil

    // Per-display frame persistence
    private var terminalFrames: [String: TerminalFrame] = [:]
    private var terminalFramesLoaded: Bool = false

    // File path for persisted frames
    private var terminalFramePath: String {
        XDG.stateHome + "/thegrid/terminal-frame.json"
    }

    init() {}

    func setup(
        stateManager: StateManager,
        windowManipulator: WindowManipulator,
        gridConfig: GridConfig
    ) {
        self.stateManager = stateManager
        self.windowManipulator = windowManipulator
        self.gridConfig = gridConfig
        jlog("term.init")
    }

    // ============================================================
    // PUBLIC: toggle -- single entry point
    // ============================================================

    func toggle() async -> CommandResult {
        guard let stateManager = stateManager else {
            return .error("terminal not initialized")
        }

        // Get fresh window manager state
        let wmState = await stateManager.getState()

        // Try to find existing terminal window
        if let windowID = findTerminalWindow(wmState) {
            return await toggleTerminalWindow(windowID, wmState)
        } else {
            return await launchTerminal()
        }
    }

    // ============================================================
    // PRIVATE: findTerminalWindow
    // ============================================================

    private func findTerminalWindow(_ wmState: WindowManagerState) -> UInt32? {
        // Fast path: check cached ID against current state
        if let cached = cachedTerminalWindowID {
            if let win = wmState.windows[String(cached)] {
                // Verify it's still the terminal (title + bundleID)
                let app = wmState.applications[String(win.pid)]
                if matchesTerminalTitle(win.title)
                    && app?.bundleIdentifier == "com.mitchellh.ghostty" {
                    return cached
                }
            }
            // Cache miss: window gone or identity changed
            cachedTerminalWindowID = nil
        }

        // Slow path: scan all windows
        for (widStr, win) in wmState.windows {
            if matchesTerminalTitle(win.title) {
                let app = wmState.applications[String(win.pid)]
                if app?.bundleIdentifier == "com.mitchellh.ghostty" {
                    if let wid = UInt32(widStr) {
                        cachedTerminalWindowID = wid
                        return wid
                    }
                }
            }
        }

        return nil
    }

    // Match both new title and legacy title for transition
    private func matchesTerminalTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title == "grid:scratch" || title == "grid-terminal"
    }

    // ============================================================
    // PRIVATE: toggleTerminalWindow
    // ============================================================

    private func toggleTerminalWindow(
        _ windowID: UInt32,
        _ wmState: WindowManagerState
    ) async -> CommandResult {
        guard let windowManipulator = windowManipulator else {
            return .error("terminal not initialized")
        }

        let win = wmState.windows[String(windowID)]

        // Use kCGWindowIsOnscreen (via wmState.isHidden) — more reliable than SLSWindowIsOrderedIn
        let isVisible = win.map { !$0.isHidden } ?? false

        // Determine if window is on the active space
        let activeSpaceID = wmState.metadata.activeSpaceID
        let onActiveSpace: Bool
        if let activeSpaceID, let win {
            onActiveSpace = win.spaces.contains(activeSpaceID)
        } else {
            onActiveSpace = false
        }

        if isVisible && onActiveSpace {
            // Save frame before hiding for per-display persistence
            loadTerminalFrames()
            if let activeDisplayUUID = wmState.metadata.activeDisplayUUID,
               let win = wmState.windows[String(windowID)] {
                let frame = TerminalFrame(
                    x: win.frame.origin.x,
                    y: win.frame.origin.y,
                    width: win.frame.width,
                    height: win.frame.height
                )
                terminalFrames[activeDisplayUUID] = frame
                saveTerminalFrames()
            }

            // Terminal is visible on this space -> hide it
            _ = windowManipulator.mssClient.orderWindowOut(windowID)
            jlog("term.hide", data: ["wid": windowID])
            return .ok("terminal hidden")
        } else {
            // Terminal is hidden or on another space -> bring here and show
            if let activeSpaceID, !onActiveSpace {
                _ = windowManipulator.mssClient.moveWindowToSpace(
                    windowID: windowID, spaceID: activeSpaceID
                )
            }

            // Reposition: restore saved position or center on display
            loadTerminalFrames()
            let activeDisplayUUID = wmState.metadata.activeDisplayUUID
            let display = wmState.displays.first(where: { $0.uuid == activeDisplayUUID })
            // Get visible frame, fall back to frame
            let displayFrame = display?.visibleFrame ?? display?.frame

            var positioned = false

            // Try to restore saved position for this display
            if let activeDisplayUUID,
               let savedFrame = terminalFrames[activeDisplayUUID],
               let displayFrame,
               let win = wmState.windows[String(windowID)] {
                let windowWidth = win.frame.width
                let windowHeight = win.frame.height

                // Bounds check: verify saved position keeps window on-screen
                let inBounds =
                    savedFrame.x >= displayFrame.origin.x
                    && savedFrame.y >= displayFrame.origin.y
                    && savedFrame.x + windowWidth <= displayFrame.origin.x + displayFrame.width
                    && savedFrame.y + windowHeight <= displayFrame.origin.y + displayFrame.height

                if inBounds,
                   let element = windowManipulator.getAXElement(pid: win.pid, windowID: windowID) {
                    _ = windowManipulator.setWindowPosition(
                        element: element,
                        point: CGPoint(x: savedFrame.x, y: savedFrame.y)
                    )
                    jlog("term.position", data: [
                        "mode": "restore",
                        "x": savedFrame.x,
                        "y": savedFrame.y,
                        "display": activeDisplayUUID
                    ])
                    positioned = true
                }
            }

            // Fall back to center mode if no saved frame or bounds check failed
            if !positioned,
               let displayFrame,
               let win = wmState.windows[String(windowID)],
               let element = windowManipulator.getAXElement(pid: win.pid, windowID: windowID) {
                // Get display offset from config (@MainActor)
                let displayName = display?.name ?? ""
                let displayUUID = display?.uuid ?? ""
                let offset = await MainActor.run {
                    gridConfig?.getDisplayOffset(uuid: displayUUID, name: displayName)
                }
                let offsetX = offset?.x ?? 0
                let offsetY = offset?.y ?? 0

                let x = displayFrame.origin.x + (displayFrame.width - win.frame.width) / 2 + offsetX
                let y = displayFrame.origin.y + (displayFrame.height - win.frame.height) / 2 + offsetY
                _ = windowManipulator.setWindowPosition(
                    element: element,
                    point: CGPoint(x: x, y: y)
                )
                jlog("term.position", data: [
                    "mode": "center",
                    "x": x,
                    "y": y,
                    "display": activeDisplayUUID ?? ""
                ])
            }

            // Show, set floating layer, and focus
            _ = windowManipulator.mssClient.orderWindowToFront(windowID)
            _ = windowManipulator.mssClient.setWindowLayer(windowID: windowID, layer: .above)
            if let pid = win?.pid {
                _ = windowManipulator.focusWindow(pid: pid, windowID: windowID)
            }

            jlog("term.show", data: ["wid": windowID])
            return .ok("terminal shown")
        }
    }

    // ============================================================
    // PRIVATE: loadTerminalFrames / saveTerminalFrames
    // ============================================================

    private func loadTerminalFrames() {
        if terminalFramesLoaded { return }
        terminalFramesLoaded = true
        terminalFrames = [:]

        guard let data = FileManager.default.contents(atPath: terminalFramePath) else {
            return
        }

        do {
            terminalFrames = try JSONDecoder().decode(
                [String: TerminalFrame].self, from: data
            )
        } catch {
            jlog("warn.term.frames.load", data: ["err": error.localizedDescription])
        }
    }

    private func saveTerminalFrames() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(terminalFrames)
            try data.write(to: URL(fileURLWithPath: terminalFramePath), options: .atomic)
        } catch {
            jlog("warn.term.frames.save", data: ["err": error.localizedDescription])
        }
    }

    // ============================================================
    // PRIVATE: findTmux
    // ============================================================

    private func findTmux() -> String {
        // Check common installation paths in order
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fall back to `which tmux` for non-standard locations
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["tmux"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !result.isEmpty {
                return result
            }
        } catch {
            // which failed, fall through to default
        }

        // Last resort default
        return "tmux"
    }

    // ============================================================
    // PRIVATE: sizeAndCenterOnDisplay
    // ============================================================

    private func sizeAndCenterOnDisplay(
        windowID: UInt32,
        pid: pid_t,
        display: DisplayState
    ) async {
        guard let windowManipulator = windowManipulator else { return }

        // Get visible frame, fall back to full frame, bail if neither available
        guard let visibleFrame = display.visibleFrame ?? display.frame else { return }

        // Calculate 80% x 60% of visible frame
        let winW = visibleFrame.width * 0.8
        let winH = visibleFrame.height * 0.6

        // Get display offset from config (@MainActor)
        let displayName = display.name ?? ""
        let displayUUID = display.uuid
        let offset = await MainActor.run { gridConfig?.getDisplayOffset(uuid: displayUUID, name: displayName) }

        // Center on display, applying offset
        let offsetX = offset?.x ?? 0
        let offsetY = offset?.y ?? 0
        let x = visibleFrame.origin.x + (visibleFrame.width - winW) / 2 + offsetX
        let y = visibleFrame.origin.y + (visibleFrame.height - winH) / 2 + offsetY

        // Apply frame via AX
        guard let element = windowManipulator.getAXElement(pid: pid, windowID: windowID) else { return }
        let frame = CGRect(x: x, y: y, width: winW, height: winH)
        _ = windowManipulator.setWindowFrame(element: element, frame: frame)

        jlog("term.sized", data: ["wid": windowID, "width": winW, "height": winH])
    }

    // ============================================================
    // PRIVATE: launchTerminal
    // ============================================================

    private func launchTerminal() async -> CommandResult {
        guard let stateManager = stateManager,
              let windowManipulator = windowManipulator else {
            return .error("terminal not initialized")
        }

        // Resolve paths
        let tmuxPath = findTmux()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Build the launch command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na", "Ghostty.app",
            "--args",
            "--title=grid:scratch",
            "--window-decoration=none",
            "--quit-after-last-window-closed=true",
            "--env=GRID_TERMINAL=scratch",
            "--command=\(shell) -l -c '\(tmuxPath) new-session -A -s grid-scratch'"
        ]

        do {
            try process.run()
        } catch {
            jlog("err.term.launch", data: ["err": error.localizedDescription])
            return .error("failed to launch terminal: \(error.localizedDescription)")
        }

        // Poll for the terminal window to appear (25 attempts x 200ms = 5s)
        let maxAttempts = 25
        for attempt in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: 200_000_000)

            let wmState = await stateManager.getState()
            if let windowID = findTerminalWindow(wmState) {
                // Size and center on active display BEFORE setting layer and focus
                if let activeDisplayUUID = wmState.metadata.activeDisplayUUID,
                   let display = wmState.displays.first(where: { $0.uuid == activeDisplayUUID }) {
                    await sizeAndCenterOnDisplay(windowID: windowID, pid: wmState.windows[String(windowID)]?.pid ?? 0, display: display)
                }

                // Set layer to above (persists across hide/show)
                _ = windowManipulator.mssClient.setWindowLayer(
                    windowID: windowID, layer: .above
                )

                // Focus the window
                if let win = wmState.windows[String(windowID)] {
                    _ = windowManipulator.focusWindow(
                        pid: win.pid, windowID: windowID
                    )
                }

                jlog("term.launched", data: [
                    "wid": windowID,
                    "attempts": attempt + 1
                ])
                return .ok("terminal launched")
            }
        }

        jlog("err.term.timeout")
        return .error("terminal launch timed out")
    }
}
