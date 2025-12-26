//
// WindowManipulator.swift
// GridServer
//
// Helper functions for manipulating windows (position, size, space, display)
//

import Foundation
import CoreGraphics
import AppKit

/// Context object for window manipulation operations
/// Passed through manipulation methods to provide state and enable immediate state updates
struct ManipulationContext {
    let windowID: UInt32
    let pid: pid_t
    var frame: CGRect?

    // Use shared StateManager - can be extended later if needed
    var stateManager: StateManager { StateManager.shared }

    init(windowID: UInt32, pid: pid_t, frame: CGRect? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
    }

    /// Create context from window state lookup
    static func from(windowID: UInt32) async -> ManipulationContext? {
        let state = await StateManager.shared.getState()
        guard let windowState = state.windows[String(windowID)] else {
            return nil
        }
        return ManipulationContext(
            windowID: windowID,
            pid: windowState.pid,
            frame: windowState.frame
        )
    }
}

/// Helper class for window manipulation operations
class WindowManipulator {
    private let connectionID: Int32
    let mssClient: MSSClient  // Internal access for MessageHandler

    init(connectionID: Int32) {
        self.connectionID = connectionID
        self.mssClient = MSSClient()
    }

    // MARK: - AX Element Lookup

    /// Get the AXUIElement for a window given its window ID and owner PID
    func getAXElement(pid: pid_t, windowID: UInt32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        // Get all windows for the application
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            Task { JSONLogger.shared.log("ax.fail", data: ["pid": pid, "reason": "windows_list"]) }
            return nil
        }

        // Find the window that matches our window ID
        for window in windows {
            if let wid = getWindowID(from: window), wid == windowID {
                return window
            }
        }

        // Fallback: If only one AX window exists, use it (handles apps like Ghostty
        // where SkyLight reports multiple phantom window IDs but AX only sees one real window)
        if windows.count == 1 {
            Task { JSONLogger.shared.log("ax.single", data: ["wid": windowID, "pid": pid]) }
            return windows[0]
        }

        Task { JSONLogger.shared.log("ax.fail", data: ["pid": pid, "wid": windowID, "reason": "not_in_list"]) }
        // Note: Don't call handleWindowDestroyed - window still exists, just can't be found by AX ID
        return nil
    }

    /// Get window ID from AX element
    private func getWindowID(from element: AXUIElement) -> UInt32? {
        var windowID: UInt32 = 0
        let result = _AXUIElementGetWindow(element, &windowID)
        return result == .success ? windowID : nil
    }

    // MARK: - Window Frame Manipulation (AX API)

    /// Set window position via AX API
    func setWindowPosition(element: AXUIElement, point: CGPoint) -> Bool {
        var mutablePoint = point
        let axValue = AXValueCreate(.cgPoint, &mutablePoint)!

        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)

        if result != AXError.success {
            Task { JSONLogger.shared.log("ax.fail", data: ["op": "position", "err": result.rawValue, "x": point.x, "y": point.y]) }
            return false
        }

        return true
    }

    /// Set window size via AX API
    func setWindowSize(element: AXUIElement, size: CGSize) -> Bool {
        var mutableSize = size
        let axValue = AXValueCreate(.cgSize, &mutableSize)!

        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)

        if result != AXError.success {
            Task { JSONLogger.shared.log("ax.fail", data: ["op": "size", "err": result.rawValue, "w": size.width, "h": size.height]) }
            return false
        }

        return true
    }

    /// Set both window position and size via AX API
    func setWindowFrame(element: AXUIElement, frame: CGRect) -> Bool {
        // Set position and size separately
        let positionSuccess = setWindowPosition(element: element, point: frame.origin)
        let sizeSuccess = setWindowSize(element: element, size: frame.size)

        return positionSuccess && sizeSuccess
    }

    // MARK: - Context-Based Frame Manipulation

    /// Move window to position using context - updates state immediately on success
    func moveWindow(context: ManipulationContext, to point: CGPoint) async -> Bool {
        guard let element = getAXElement(pid: context.pid, windowID: context.windowID) else {
            return false
        }
        let result = setWindowPosition(element: element, point: point)
        if result {
            let currentSize = context.frame?.size ?? CGSize(width: 100, height: 100)
            let newFrame = CGRect(origin: point, size: currentSize)
            await context.stateManager.setWindowFrame(context.windowID, frame: newFrame)
        }
        return result
    }

    /// Resize window using context - updates state immediately on success
    func resizeWindow(context: ManipulationContext, to size: CGSize) async -> Bool {
        guard let element = getAXElement(pid: context.pid, windowID: context.windowID) else {
            return false
        }
        let result = setWindowSize(element: element, size: size)
        if result {
            let currentOrigin = context.frame?.origin ?? CGPoint.zero
            let newFrame = CGRect(origin: currentOrigin, size: size)
            await context.stateManager.setWindowFrame(context.windowID, frame: newFrame)
        }
        return result
    }

    /// Set window frame using context - updates state immediately on success
    func setWindowFrame(context: ManipulationContext, frame: CGRect) async -> Bool {
        guard let element = getAXElement(pid: context.pid, windowID: context.windowID) else {
            return false
        }
        let result = setWindowFrame(element: element, frame: frame)
        if result {
            await context.stateManager.setWindowFrame(context.windowID, frame: frame)
        }
        return result
    }

    /// Minimize window using context - updates state immediately on success
    func minimizeWindow(context: ManipulationContext) async -> Bool {
        let result = mssClient.minimizeWindow(context.windowID)
        if result {
            await context.stateManager.setWindowMinimized(context.windowID, minimized: true)
        }
        return result
    }

    /// Unminimize window using context - updates state immediately on success
    func unminimizeWindow(context: ManipulationContext) async -> Bool {
        let result = mssClient.unminimizeWindow(context.windowID)
        if result {
            await context.stateManager.setWindowMinimized(context.windowID, minimized: false)
        }
        return result
    }

    // MARK: - Space Manipulation

    /// Check if we need to use the compatibility workspace workaround
    private func needsCompatibilityWorkaround() -> Bool {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion

        if osVersion.majorVersion == 12 && osVersion.minorVersion >= 7 { return true }
        if osVersion.majorVersion == 13 && osVersion.minorVersion >= 6 { return true }
        if osVersion.majorVersion == 14 && osVersion.minorVersion >= 5 { return true }

        return osVersion.majorVersion >= 15
    }

    /// Create a CFArray of window IDs (matching yabai's cfarray_of_cfnumbers)
    private func createWindowArray(windowIDs: [UInt32]) -> CFArray {
        // Create CFNumbers for each window ID
        let cfNumbers: [CFNumber] = windowIDs.map { wid -> CFNumber in
            var id = wid
            return CFNumberCreate(nil, .sInt32Type, &id)!
        }

        // Convert to NSArray then to CFArray (Swift handles this correctly)
        let nsArray = cfNumbers as NSArray
        return nsArray as CFArray
        // Note: Swift auto-manages CF objects, no manual release needed
    }

    /// Get the current space ID for a window
    private func getWindowSpace(windowID: UInt32) -> UInt64? {
        // Create CFArray with single window ID
        let windowArray = createWindowArray(windowIDs: [windowID])
        // Note: Swift auto-manages CF objects

        // Query spaces for this window
        guard let spaceArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) else {
            return nil
        }

        let count = CFArrayGetCount(spaceArray)
        guard count > 0 else { return nil }

        // Extract space ID from CFArray
        let spacePtr = CFArrayGetValueAtIndex(spaceArray, 0)
        let spaceNumber = Unmanaged<CFNumber>.fromOpaque(spacePtr!).takeUnretainedValue()

        var spaceValue: UInt64 = 0
        CFNumberGetValue(spaceNumber, .sInt64Type, &spaceValue)

        return spaceValue
    }

    /// Move window using compatibility workspace IDs (for modern macOS)
    private func moveWindowViaCompatibilityWorkspace(windowID: UInt32, spaceID: UInt64) -> Bool {
        Task { JSONLogger.shared.log("sls.compat", data: ["wid": windowID, "sid": spaceID]) }

        // Use "grid" as magic constant (0x67726964)
        let compatID: Int32 = 0x67726964

        // Set space compatibility ID
        var result = SLSSpaceSetCompatID(connectionID, spaceID, compatID)

        if result != .success {
            Task { JSONLogger.shared.log("err.sls", data: ["op": "set_compat", "err": result.rawValue, "sid": spaceID]) }
            return false
        }

        // Move window to workspace
        var wid = windowID
        result = SLSSetWindowListWorkspace(connectionID, &wid, 1, compatID)

        // Always clean up - reset compat ID to 0
        let resetResult = SLSSpaceSetCompatID(connectionID, spaceID, 0)
        if resetResult != .success {
            Task { JSONLogger.shared.log("warn.sls", data: ["op": "reset_compat", "err": resetResult.rawValue]) }
        }

        if result != .success {
            Task { JSONLogger.shared.log("err.sls", data: ["op": "workspace", "err": result.rawValue, "wid": windowID]) }
            return false
        }

        return true
    }

    /// Move window using direct SLSMoveWindowsToManagedSpace API
    private func moveWindowViaSkyLightAPI(windowID: UInt32, spaceID: UInt64) -> Bool {
        Task { JSONLogger.shared.log("sls.move", data: ["wid": windowID, "sid": spaceID]) }

        // Create CFArray with proper kCFTypeArrayCallBacks
        let windowArray = createWindowArray(windowIDs: [windowID])
        // Note: Swift auto-manages CF objects

        // Call the API
        SLSMoveWindowsToManagedSpace(connectionID, windowArray, spaceID)

        return true
    }

    /// Move a window to a specific space
    func moveWindowToSpace(windowID: UInt32, spaceID: UInt64) -> Bool {
        Task { JSONLogger.shared.log("win.space", data: ["wid": windowID, "sid": spaceID]) }

        // Validate space type - don't allow moves to fullscreen spaces
        let spaceType = SLSSpaceGetType(connectionID, spaceID)

        if spaceType == SpaceType.fullscreen.rawValue {
            Task { JSONLogger.shared.log("err.space", data: ["reason": "fullscreen", "sid": spaceID]) }
            return false
        }

        // Check current space
        let currentSpace = getWindowSpace(windowID: windowID)

        if currentSpace == spaceID {
return true
        }

        // Determine method based on macOS version and MSS availability
        let needsWorkaround = needsCompatibilityWorkaround()

        if needsWorkaround {
            // macOS 12.7+, 13.6+, 14.5+, 15+ - try MSS first, then fail gracefully
            if mssClient.isAvailable() {

                // Use MSS to move window
                let success = mssClient.moveWindowToSpace(windowID: windowID, spaceID: spaceID)

                if !success {
                    Task { JSONLogger.shared.log("mss.fail", data: ["op": "move", "wid": windowID, "sid": spaceID]) }
                    return false
                }

                // Verify the move
                let newSpace = getWindowSpace(windowID: windowID)
                let verified = newSpace == spaceID

                if verified {
                    Task { JSONLogger.shared.log("mss.move", data: ["wid": windowID, "sid": spaceID]) }
                    return true
                } else {
                    Task { JSONLogger.shared.log("err.verify", data: ["wid": windowID, "expected": spaceID, "actual": newSpace as Any]) }
                    return false
                }

            } else {
                // MSS not available
                Task { JSONLogger.shared.log("warn.mss", data: ["reason": "not_available"]) }
                return false
            }
        } else {
            // Older macOS - use direct API

            let success = moveWindowViaSkyLightAPI(windowID: windowID, spaceID: spaceID)

            if !success {
                Task { JSONLogger.shared.log("err.sls", data: ["op": "move"]) }
                return false
            }

            let newSpace = getWindowSpace(windowID: windowID)
            let verified = newSpace == spaceID

            if !verified {
                Task { JSONLogger.shared.log("err.verify", data: ["wid": windowID, "expected": spaceID, "actual": newSpace as Any]) }
            }

            return verified
        }
    }

    // MARK: - Window Focus

    /// Synthesize key window events using yabai's byte pattern
    /// This sends two events to make the window the key window
    private func makeKeyWindow(psn: UnsafePointer<ProcessSerialNumber>, windowID: UInt32) {
        // 0xf8 (248) byte event buffer - yabai pattern
        var eventBytes = [UInt8](repeating: 0, count: 0xf8)

        eventBytes[0x04] = 0xf8                      // Size field
        eventBytes[0x3a] = 0x10                      // Event type marker

        // Window ID at offset 0x3c (4 bytes, little-endian)
        withUnsafeBytes(of: windowID.littleEndian) { idBytes in
            for i in 0..<4 { eventBytes[0x3c + i] = idBytes[i] }
        }

        // Fill 0x20-0x2f with 0xff (identity/session marker)
        for i in 0x20...0x2f { eventBytes[i] = 0xff }

        // Post event type 0x01
        eventBytes[0x08] = 0x01
        eventBytes.withUnsafeMutableBufferPointer { buf in
            _ = SLPSPostEventRecordTo(psn, buf.baseAddress!)
        }

        // Post event type 0x02
        eventBytes[0x08] = 0x02
        eventBytes.withUnsafeMutableBufferPointer { buf in
            _ = SLPSPostEventRecordTo(psn, buf.baseAddress!)
        }
    }

    /// Focus window with yabai-style raise (handles same-app windows properly)
    /// Uses: _SLPSSetFrontProcessWithOptions + event synthesis + AXRaise
    private func focusWindowWithRaise(pid: pid_t, windowID: UInt32) -> Bool {
        // 1. Get PSN from PID
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard GetProcessForPID(pid, &psn) == 0 else {
            Task { JSONLogger.shared.log("warn.focus", data: ["reason": "psn_fail", "pid": pid]) }
            return focusWindowFallback(pid: pid, windowID: windowID)
        }

        // 2. Set front process with window context
        withUnsafePointer(to: psn) { psnPtr in
            _ = SLPSSetFrontProcessWithOptions(psnPtr, windowID, kCPSUserGenerated)
        }

        // 3. Synthesize key window events
        withUnsafePointer(to: psn) { psnPtr in
            makeKeyWindow(psn: psnPtr, windowID: windowID)
        }

        // 4. AX raise as final step (same order as yabai)
        if let element = getAXElement(pid: pid, windowID: windowID) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }

        return true
    }

    /// Fallback focus method (MSS + NSRunningApplication + AX)
    private func focusWindowFallback(pid: pid_t, windowID: UInt32) -> Bool {
        if mssClient.isAvailable() {
            _ = mssClient.orderWindowToFront(windowID)
            _ = mssClient.focusWindow(windowID)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        if let element = getAXElement(pid: pid, windowID: windowID) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        return true
    }

    /// Focus a window by raising it and activating its app
    /// Uses yabai-style event synthesis for reliable same-app window focus
    func focusWindow(pid: pid_t, windowID: UInt32) -> Bool {
        Task { JSONLogger.shared.log("win.focus", data: ["pid": pid, "wid": windowID]) }

        let result = focusWindowWithRaise(pid: pid, windowID: windowID)

        if !result {
            Task { JSONLogger.shared.log("err.focus", data: ["wid": windowID]) }
        }
        return result
    }

    /// Focus a window using context - updates state immediately on success
    func focusWindow(context: ManipulationContext) async -> Bool {
        let result = focusWindow(pid: context.pid, windowID: context.windowID)
        if result {
            await context.stateManager.setFocusedWindow(context.windowID)
        }
        return result
    }

    // MARK: - Display Manipulation

    /// Move window to a specific display (and optionally position it)
    func moveWindowToDisplay(windowID: UInt32, displayUUID: String, position: CGPoint?, stateManager: StateManager) async -> Bool {
        // Find a space on the target display
        let state = await stateManager.getState()
        guard let targetSpace = state.spaces.values.first(where: { $0.displayUUID == displayUUID }) else {
            Task { JSONLogger.shared.log("err.display", data: ["reason": "no_space", "uuid": displayUUID]) }
            return false
        }

        Task { JSONLogger.shared.log("win.move", data: ["wid": windowID, "display": displayUUID, "sid": targetSpace.id]) }

        // First, move the window to a space on that display
        if !moveWindowToSpace(windowID: windowID, spaceID: targetSpace.id) {
            return false
        }

        // If a position was specified, set it
        if let position = position {
            // Get the window from state to find its PID
            guard let windowState = state.windows[String(windowID)],
                  let element = getAXElement(pid: windowState.pid, windowID: windowID) else {
                Task { JSONLogger.shared.log("err.ax", data: ["op": "get_element", "wid": windowID]) }
                return false
            }

            // Set the position
            if !setWindowPosition(element: element, point: position) {
                Task { JSONLogger.shared.log("warn.move", data: ["reason": "position_fail", "wid": windowID]) }
                return false
            }
        }

        // Re-query space assignment after successful move
        await stateManager.updateWindowSpacesPublic(windowID)

        return true
    }
}

// External C function for getting window ID from AX element
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<UInt32>) -> AXError
