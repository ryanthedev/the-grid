import Foundation
import CoreGraphics
import AppKit

// MARK: - Frame Persistence Data

/// Codable representation of a CGRect for JSON serialization.
/// Fields use short names (x, y, w, h) to keep the state file compact.
private struct FrameData: Codable {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
}

/// Load saved terminal frames from disk. Returns the deserialized dictionary.
/// Top-level function to avoid actor isolation issues when called from init.
/// Silently returns empty dictionary for missing or corrupt files.
private func loadTerminalFramesFromDisk() -> [String: CGRect] {
    let path = "\(XDG.stateHome)/thegrid/terminal-frames.json"
    guard FileManager.default.fileExists(atPath: path) else { return [:] }

    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode([String: FrameData].self, from: data)
        var frames: [String: CGRect] = [:]
        for (uuid, fd) in decoded {
            frames[uuid] = CGRect(x: fd.x, y: fd.y, width: fd.w, height: fd.h)
        }
        jlog("term.frames.loaded", data: ["count": decoded.count])
        return frames
    } catch {
        jlog("err.term.frames.load", msg: "\(error)")
        return [:]
    }
}

// MARK: - GridTerminalManager

/// Manages a single Ghostty terminal window that toggles on/off as a dropdown.
///
/// Encapsulates all terminal state: tracked window ID/PID, per-display frame
/// persistence, hide/show mechanics (MSS opacity + off-screen move), and
/// Ghostty launch with tmux session attachment.
///
/// The single public method `toggle()` uses 4-tier resolution:
///   1. Saved PID alive + saved WID valid -> hide or show
///   2. PID alive, WID stale -> re-query StateManager, hide
///   3. No saved state -> search for orphaned Ghostty window, hide
///   4. No Ghostty found -> launch new instance
actor GridTerminalManager {

    // MARK: - Constants

    private static let ghosttyBundleID = "com.mitchellh.ghostty"
    private static let ghosttyTitle = "grid:scratch"
    private static let offScreenPoint = CGPoint(x: -10000, y: -10000)
    private static let framePersistencePath = "\(XDG.stateHome)/thegrid/terminal-frames.json"

    /// Polling interval (milliseconds) when waiting for Ghostty window after launch
    private static let pollIntervalMs = 100

    /// Maximum poll attempts (100ms x 50 = 5 seconds)
    private static let pollMaxAttempts = 50

    /// Default terminal width as fraction of display visible area
    private static let defaultWidthRatio: CGFloat = 0.80

    /// Default terminal height as fraction of display visible area
    private static let defaultHeightRatio: CGFloat = 0.60

    // MARK: - Dependencies (constructor-injected)

    private let windowManipulator: WindowManipulator
    private let stateManager: StateManager
    private let gridReconciler: GridReconciler

    // MARK: - Mutable State

    /// Tracked Ghostty window ID (nil until first toggle resolves a window)
    private var savedWindowID: UInt32?

    /// Tracked Ghostty process ID (nil until first toggle resolves a window)
    private var savedPID: pid_t?

    /// Whether the terminal is currently hidden (opacity 0 + off-screen).
    /// Tracked internally because our hide approach does not change OS-level
    /// ordered-in state -- the window is still technically ordered in.
    private var isHidden: Bool = false

    /// Guard against re-entrant toggle calls during async suspension points
    private var toggling: Bool = false

    /// Per-display saved frames, keyed by display UUID string.
    /// Persisted to disk so frames survive server restarts.
    private var displayFrames: [String: CGRect] = [:]

    /// Window that was focused before the terminal was shown.
    /// Used to restore focus when hiding the terminal.
    private var previousWindowID: UInt32?

    // MARK: - Initialization

    init(windowManipulator: WindowManipulator, stateManager: StateManager, gridReconciler: GridReconciler) {
        self.windowManipulator = windowManipulator
        self.stateManager = stateManager
        self.gridReconciler = gridReconciler
        self.displayFrames = loadTerminalFramesFromDisk()
    }

    // MARK: - Public API

    /// Toggle the Ghostty terminal: show if hidden, hide if visible, launch if absent.
    func toggle() async -> CommandResult {
        // Guard against re-entrant toggle during async suspension
        if toggling {
            jlog("term.toggle.skip", msg: "already toggling")
            return .ok("toggle in progress")
        }

        toggling = true
        defer { toggling = false }

        // Suppress reconciler for entire toggle to prevent border/assignment side effects
        gridReconciler.setSuppressed(true, syncOnResume: false)
        defer { gridReconciler.setSuppressed(false, syncOnResume: true) }

        // Tier 1: Saved PID alive + saved WID valid in StateManager
        if let pid = savedPID, let wid = savedWindowID {
            if isPIDAlive(pid) {
                if await windowExistsInState(wid) {
                    if isHidden {
                        await show(wid: wid, pid: pid)
                    } else {
                        await hide(wid: wid, pid: pid)
                    }
                    return .ok(isHidden ? "hidden" : "shown")
                }
            }
        }

        // Tier 2: PID alive, WID stale -- re-query StateManager for matching window
        if let pid = savedPID, isPIDAlive(pid) {
            if let wid = await findGhosttyWindow(byPID: pid) {
                savedWindowID = wid
                // Found via re-query; window is visible (we did not hide it), so hide
                await hide(wid: wid, pid: pid)
                return .ok("hidden")
            }
        }

        // Tier 3: No saved state -- search for orphaned Ghostty window
        if let (wid, pid) = await findAnyGhosttyWindow() {
            savedWindowID = wid
            savedPID = pid
            // Orphaned window found; treat as currently shown, hide it
            await hide(wid: wid, pid: pid)
            return .ok("hidden")
        }

        // Tier 4: No Ghostty window exists -- launch one
        let result = await launchGhostty()
        return result
    }

    // MARK: - Hide / Show

    /// Hide the terminal by setting opacity to 0 and moving off-screen.
    /// Saves current frame keyed by display UUID before hiding.
    private func hide(wid: UInt32, pid: pid_t) async {
        jlog("term.hide", data: ["wid": wid])

        // Save current frame keyed by display UUID before hiding
        let currentFrame = await getCurrentFrame(wid: wid)
        let displayUUID = await getDisplayUUID(forWindow: wid)
        if let frame = currentFrame, let uuid = displayUUID {
            saveFrame(displayUUID: uuid, frame: frame)
        }

        // Set opacity to 0 (cross-process via MSS)
        _ = windowManipulator.mssClient.setWindowOpacity(windowID: wid, opacity: 0.0)

        // Move off-screen via AX API
        if let element = windowManipulator.getAXElement(pid: pid, windowID: wid) {
            _ = windowManipulator.setWindowPosition(element: element, point: Self.offScreenPoint)
        }

        // Restore focus to the window that was active before terminal was shown
        if let prevWID = previousWindowID {
            let state = await stateManager.getState()
            let key = String(prevWID)
            if let window = state.windows[key] {
                _ = windowManipulator.focusWindow(pid: window.pid, windowID: prevWID)
            }
            previousWindowID = nil
        }

        isHidden = true
    }

    /// Show the terminal by restoring frame and opacity, then focusing.
    /// Uses per-display saved frame or computes a default centered frame.
    private func show(wid: UInt32, pid: pid_t) async {
        jlog("term.show", data: ["wid": wid])

        // Save currently focused window so we can restore on hide
        let state = await stateManager.getState()
        previousWindowID = state.metadata.focusedWindowID

        // Determine target frame: saved per-display frame or centered default
        let displayUUID = await getActiveDisplayUUID()
        let targetFrame: CGRect
        if let uuid = displayUUID, let savedFrame = restoreFrame(displayUUID: uuid) {
            targetFrame = savedFrame
        } else {
            targetFrame = await computeDefaultFrame(displayUUID: displayUUID)
        }

        // Move to target position via AX API
        if let element = windowManipulator.getAXElement(pid: pid, windowID: wid) {
            _ = windowManipulator.setWindowFrame(element: element, frame: targetFrame)
        }

        // Set opacity to 1.0 (cross-process via MSS)
        _ = windowManipulator.mssClient.setWindowOpacity(windowID: wid, opacity: 1.0)

        // Bring to front and focus
        _ = windowManipulator.mssClient.orderWindowToFront(wid)
        _ = windowManipulator.focusWindow(pid: pid, windowID: wid)

        isHidden = false
    }

    // MARK: - Window Resolution

    /// Check if a process is alive using POSIX signal 0
    private func isPIDAlive(_ pid: pid_t) -> Bool {
        return Darwin.kill(pid, 0) == 0
    }

    /// Check if a window ID exists in StateManager's current state
    private func windowExistsInState(_ wid: UInt32) async -> Bool {
        let state = await stateManager.getState()
        return state.windows[String(wid)] != nil
    }

    /// Find a Ghostty window owned by a known PID.
    /// Checks title first, falls back to single-window heuristic.
    private func findGhosttyWindow(byPID pid: pid_t) async -> UInt32? {
        let state = await stateManager.getState()

        // Primary: match by PID and title containing "grid:scratch"
        for (_, window) in state.windows {
            if window.pid == pid {
                if let title = window.title, title.contains(Self.ghosttyTitle) {
                    return window.id
                }
            }
        }

        // Fallback: if PID matches exactly one window, use it
        // (handles Ghostty title changes from tmux pane switches)
        let pidWindows = state.windows.values.filter { $0.pid == pid }
        if pidWindows.count == 1 {
            return pidWindows.first?.id
        }

        return nil
    }

    /// Search all windows for any Ghostty window with matching title.
    /// Used when no saved PID/WID exists (tier 3: orphaned window).
    private func findAnyGhosttyWindow() async -> (UInt32, pid_t)? {
        let state = await stateManager.getState()

        for (_, window) in state.windows {
            let pidStr = String(window.pid)
            if let app = state.applications[pidStr],
               app.bundleIdentifier == Self.ghosttyBundleID {
                if let title = window.title, title.contains(Self.ghosttyTitle) {
                    return (window.id, window.pid)
                }
            }
        }

        return nil
    }

    // MARK: - Ghostty Launch (Tier 4)

    /// Launch a new Ghostty instance with tmux session attachment.
    /// Polls for window appearance up to 5 seconds, then positions and focuses.
    private func launchGhostty() async -> CommandResult {
        jlog("term.launch")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let tmux = resolveBinaryPath("tmux") ?? "/opt/homebrew/bin/tmux"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na", "Ghostty.app",
            "--args",
            "--title=grid:scratch",
            "--window-decoration=none",
            "--quit-after-last-window-closed=true",
            "--env=GRID_TERMINAL=scratch",
            "--command=\(shell) -l -c '\(tmux) new-session -A -s grid-scratch'"
        ]

        do {
            try process.run()
        } catch {
            jlog("err.term.launch", msg: "\(error)")
            return .error("failed to launch Ghostty")
        }

        // Poll for window appearance (100ms x 50 = 5s max)
        var foundWID: UInt32?
        var foundPID: pid_t?
        for _ in 0..<Self.pollMaxAttempts {
            try? await Task.sleep(for: .milliseconds(Self.pollIntervalMs))
            if let (wid, pid) = await findAnyGhosttyWindow() {
                foundWID = wid
                foundPID = pid
                break
            }
        }

        guard let wid = foundWID, let pid = foundPID else {
            jlog("err.term.timeout", msg: "Ghostty window did not appear within 5s")
            return .error("Ghostty window did not appear within 5s")
        }

        // Save state
        savedWindowID = wid
        savedPID = pid
        isHidden = false

        // Position: centered at default ratio on active display
        let displayUUID = await getActiveDisplayUUID()
        let targetFrame = await computeDefaultFrame(displayUUID: displayUUID)

        if let element = windowManipulator.getAXElement(pid: pid, windowID: wid) {
            _ = windowManipulator.setWindowFrame(element: element, frame: targetFrame)
        }

        // Set layer to "above" so terminal floats over other windows
        _ = windowManipulator.mssClient.setWindowLayer(windowID: wid, layer: .above)

        // Focus the new window
        _ = windowManipulator.focusWindow(pid: pid, windowID: wid)

        // Save initial frame for this display
        if let uuid = displayUUID {
            saveFrame(displayUUID: uuid, frame: targetFrame)
        }

        jlog("term.launched", data: ["wid": wid, "pid": pid])
        return .ok("launched")
    }

    // MARK: - Display and Frame Helpers

    /// Get the active display UUID from StateManager metadata
    private func getActiveDisplayUUID() async -> String? {
        let state = await stateManager.getState()
        return state.metadata.activeDisplayUUID
    }

    /// Get the display UUID for a specific window from StateManager
    private func getDisplayUUID(forWindow wid: UInt32) async -> String? {
        let state = await stateManager.getState()
        return state.windows[String(wid)]?.displayUUID
    }

    /// Get the current frame for a window from StateManager
    private func getCurrentFrame(wid: UInt32) async -> CGRect? {
        let state = await stateManager.getState()
        return state.windows[String(wid)]?.frame
    }

    /// Compute a default centered frame at 80% width x 60% height of the display's
    /// visible area (excluding menu bar and dock). Falls back to 1920x1080 if no
    /// display information is available.
    private func computeDefaultFrame(displayUUID: String?) async -> CGRect {
        let state = await stateManager.getState()

        // Find the display's visible frame, falling back to a reasonable default
        var visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        if let uuid = displayUUID {
            for display in state.displays {
                if display.uuid == uuid {
                    visibleFrame = display.visibleFrame ?? display.frame ?? visibleFrame
                    break
                }
            }
        }

        // Compute centered rectangle at default ratios
        let width = visibleFrame.width * Self.defaultWidthRatio
        let height = visibleFrame.height * Self.defaultHeightRatio
        let x = visibleFrame.origin.x + (visibleFrame.width - width) / 2
        let y = visibleFrame.origin.y + (visibleFrame.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Frame Persistence

    /// Save a frame for a display and flush to disk.
    /// Called on hide to remember where the terminal was positioned.
    private func saveFrame(displayUUID: String, frame: CGRect) {
        displayFrames[displayUUID] = frame
        flushFramesToDisk()
    }

    /// Restore a previously saved frame for a display.
    /// Returns nil if no frame was saved for this display.
    private func restoreFrame(displayUUID: String) -> CGRect? {
        return displayFrames[displayUUID]
    }

    /// Flush in-memory frame dictionary to disk as JSON.
    /// Creates the parent directory if it does not exist.
    /// Writes are infrequent (only on hide), so synchronous I/O is acceptable.
    private func flushFramesToDisk() {
        var encoded: [String: FrameData] = [:]
        for (uuid, rect) in displayFrames {
            encoded[uuid] = FrameData(
                x: rect.origin.x,
                y: rect.origin.y,
                w: rect.size.width,
                h: rect.size.height
            )
        }

        do {
            let data = try JSONEncoder().encode(encoded)
            let dir = (Self.framePersistencePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: Self.framePersistencePath))
        } catch {
            jlog("err.term.frames.save", msg: "\(error)")
        }
    }

    /// Resolve a binary name to its full path using the server process's PATH.
    /// Falls back to common homebrew locations if not found in PATH.
    private func resolveBinaryPath(_ name: String) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in pathDirs + fallbacks {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }
}
