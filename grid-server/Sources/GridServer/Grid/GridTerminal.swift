import Foundation
import CoreGraphics

class GridTerminal {

    // Dependencies (weak references, set via setup)
    private weak var stateManager: StateManager?
    private weak var windowManipulator: WindowManipulator?
    private weak var gridConfig: GridConfig?

    // Cached terminal window ID to avoid full-scan on every toggle
    private var cachedTerminalWindowID: UInt32? = nil

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
                if win.title == "grid-terminal"
                    && app?.bundleIdentifier == "com.mitchellh.ghostty" {
                    return cached
                }
            }
            // Cache miss: window gone or identity changed
            cachedTerminalWindowID = nil
        }

        // Slow path: scan all windows
        for (widStr, win) in wmState.windows {
            if win.title == "grid-terminal" {
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

                // Reposition onto the active display so it's visible after cross-display move
                if let win,
                   let activeDisplayUUID = wmState.metadata.activeDisplayUUID,
                   let display = wmState.displays.first(where: { $0.uuid == activeDisplayUUID }),
                   let displayFrame = display.visibleFrame,
                   let element = windowManipulator.getAXElement(pid: win.pid, windowID: windowID) {
                    // Center horizontally, place near top of display
                    let x = displayFrame.origin.x + (displayFrame.width - win.frame.width) / 2
                    let y = displayFrame.origin.y
                    _ = windowManipulator.setWindowPosition(element: element, point: CGPoint(x: x, y: y))
                }
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
    // PRIVATE: launchTerminal
    // ============================================================

    private func launchTerminal() async -> CommandResult {
        guard let stateManager = stateManager,
              let windowManipulator = windowManipulator else {
            return .error("terminal not initialized")
        }

        // Build the launch command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na", "Ghostty.app",
            "--args",
            "--title=grid-terminal",
            "--window-decoration=none",
            "-e", "tmux", "new-session", "-A", "-s", "grid-scratch"
        ]

        do {
            try process.run()
        } catch {
            jlog("err.term.launch", data: ["err": error.localizedDescription])
            return .error("failed to launch terminal: \(error.localizedDescription)")
        }

        // Poll for the terminal window to appear (up to 3 seconds)
        let maxAttempts = 15
        for attempt in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: 200_000_000)

            let wmState = await stateManager.getState()
            if let windowID = findTerminalWindow(wmState) {
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
