//
// WindowManipulator.swift
// GridServer
//
// Helper functions for manipulating windows (position, size, space, display)
//

import Foundation
import CoreGraphics
import AppKit
import Logging

/// Helper class for window manipulation operations
class WindowManipulator {
    private let connectionID: Int32
    private let logger: Logger
    let mssClient: MSSClient  // Internal access for MessageHandler

    init(connectionID: Int32, logger: Logger) {
        self.connectionID = connectionID
        self.logger = logger
        self.mssClient = MSSClient(logger: logger)
    }

    // MARK: - AX Element Lookup

    /// Get the AXUIElement for a window given its window ID and owner PID
    func getAXElement(pid: pid_t, windowID: UInt32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        // Get all windows for the application
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            logger.debug("Failed to get windows for app", metadata: ["pid": "\(pid)"])
            return nil
        }

        // Find the window that matches our window ID
        for window in windows {
            if let wid = getWindowID(from: window), wid == windowID {
                return window
            }
        }

        logger.debug("Window not found in app's window list", metadata: [
            "pid": "\(pid)",
            "windowID": "\(windowID)"
        ])
        StateManager.shared.handleWindowDestroyed(windowID)
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
            logger.debug("Failed to set window position", metadata: [
                "error": "\(result.rawValue)",
                "x": "\(point.x)",
                "y": "\(point.y)"
            ])
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
            logger.debug("Failed to set window size", metadata: [
                "error": "\(result.rawValue)",
                "width": "\(size.width)",
                "height": "\(size.height)"
            ])
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
        logger.debug("Using compat workspace method", metadata: [
            "windowID": "\(windowID)",
            "spaceID": "\(spaceID)"
        ])

        // Use "grid" as magic constant (0x67726964)
        let compatID: Int32 = 0x67726964
        logger.debug("Setting compat ID on space", metadata: [
            "compatID": "0x\(String(compatID, radix: 16))",
            "compatIDDecimal": "\(compatID)",
            "connectionID": "\(connectionID)"
        ])

        // Set space compatibility ID
        var result = SLSSpaceSetCompatID(connectionID, spaceID, compatID)
        logger.debug("SLSSpaceSetCompatID returned", metadata: [
            "CGError": "\(result.rawValue)",
            "CGErrorHex": "0x\(String(result.rawValue, radix: 16))",
            "description": result == .success ? "success" : "FAILED"
        ])

        if result != .success {
            logger.error("SLSSpaceSetCompatID failed", metadata: [
                "error": "\(result.rawValue)",
                "spaceID": "\(spaceID)",
                "compatID": "\(compatID)"
            ])
            return false
        }

        // Move window to workspace
        var wid = windowID
        logger.debug("Calling SLSSetWindowListWorkspace", metadata: [
            "windowID": "\(wid)",
            "count": "1",
            "workspaceID": "\(compatID)"
        ])

        result = SLSSetWindowListWorkspace(connectionID, &wid, 1, compatID)
        logger.debug("SLSSetWindowListWorkspace returned", metadata: [
            "CGError": "\(result.rawValue)",
            "description": result == .success ? "success" : "FAILED"
        ])

        // Always clean up - reset compat ID to 0
        logger.debug("Resetting compat ID to 0")
        let resetResult = SLSSpaceSetCompatID(connectionID, spaceID, 0)
        if resetResult != .success {
            logger.warning("Reset compat ID failed (non-fatal)", metadata: [
                "error": "\(resetResult.rawValue)"
            ])
        }

        if result != .success {
            logger.error("SLSSetWindowListWorkspace failed", metadata: [
                "error": "\(result.rawValue)",
                "windowID": "\(windowID)",
                "workspaceID": "\(compatID)"
            ])
            return false
        }

        return true
    }

    /// Move window using direct SLSMoveWindowsToManagedSpace API
    private func moveWindowViaSkyLightAPI(windowID: UInt32, spaceID: UInt64) -> Bool {
        logger.debug("Using direct SLSMoveWindowsToManagedSpace API")

        // Create CFArray with proper kCFTypeArrayCallBacks
        let windowArray = createWindowArray(windowIDs: [windowID])
        // Note: Swift auto-manages CF objects

        // Call the API
        SLSMoveWindowsToManagedSpace(connectionID, windowArray, spaceID)

        logger.debug("Called SLSMoveWindowsToManagedSpace")
        return true
    }

    /// Move a window to a specific space
    func moveWindowToSpace(windowID: UInt32, spaceID: UInt64) -> Bool {
        logger.debug("Moving window to space", metadata: [
            "windowID": "\(windowID)",
            "spaceID": "\(spaceID)"
        ])

        // Validate space type - don't allow moves to fullscreen spaces
        let spaceType = SLSSpaceGetType(connectionID, spaceID)
        let spaceTypeName = SpaceType(rawValue: spaceType)?.description ?? "unknown"
        logger.debug("Target space type", metadata: [
            "spaceID": "\(spaceID)",
            "typeRaw": "\(spaceType)",
            "typeName": "\(spaceTypeName)"
        ])

        if spaceType == SpaceType.fullscreen.rawValue {
            logger.error("Cannot move to fullscreen space", metadata: ["spaceID": "\(spaceID)"])
            return false
        }

        // Check current space
        let currentSpace = getWindowSpace(windowID: windowID)
        logger.debug("Window current space", metadata: [
            "windowID": "\(windowID)",
            "currentSpace": "\(currentSpace?.description ?? "unknown")"
        ])

        if currentSpace == spaceID {
            logger.debug("Window already on target space", metadata: ["windowID": "\(windowID)"])
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
                    logger.error("MSS move failed", metadata: ["windowID": "\(windowID)", "spaceID": "\(spaceID)"])
                    return false
                }

                // Verify the move
                let newSpace = getWindowSpace(windowID: windowID)
                let verified = newSpace == spaceID

                if verified {
                    logger.debug("Window moved via MSS", metadata: [
                        "windowID": "\(windowID)",
                        "from": "\(currentSpace?.description ?? "?")",
                        "to": "\(spaceID)"
                    ])
                    return true
                } else {
                    logger.error("MSS move verification failed", metadata: [
                        "windowID": "\(windowID)",
                        "expected": "\(spaceID)",
                        "actual": "\(newSpace?.description ?? "?")"
                    ])
                    return false
                }

            } else {
                // MSS not available
                logger.warning("MSS not available - window move to space requires MSS on macOS 12.7+")
                return false
            }
        } else {
            // Older macOS - use direct API

            let success = moveWindowViaSkyLightAPI(windowID: windowID, spaceID: spaceID)

            if !success {
                logger.error("Direct SLS API failed")
                return false
            }

            let newSpace = getWindowSpace(windowID: windowID)
            let verified = newSpace == spaceID

            if !verified {
                logger.error("Move verification failed", metadata: [
                    "windowID": "\(windowID)",
                    "expected": "\(spaceID)",
                    "actual": "\(newSpace?.description ?? "?")"
                ])
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
            logger.warning("GetProcessForPID failed, using fallback", metadata: ["pid": "\(pid)"])
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
        logger.debug("Focusing window", metadata: [
            "pid": "\(pid)",
            "windowID": "\(windowID)"
        ])

        let result = focusWindowWithRaise(pid: pid, windowID: windowID)

        logger.info("Window focused", metadata: ["windowID": "\(windowID)", "success": "\(result)"])
        return result
    }

    // MARK: - Display Manipulation

    /// Move window to a specific display (and optionally position it)
    func moveWindowToDisplay(windowID: UInt32, displayUUID: String, position: CGPoint?, stateManager: StateManager) -> Bool {
        // Find a space on the target display
        guard let targetSpace = stateManager.getState().spaces.values.first(where: { $0.displayUUID == displayUUID }) else {
            logger.error("No space found on target display", metadata: ["displayUUID": "\(displayUUID)"])
            return false
        }

        logger.debug("Moving window to display", metadata: [
            "windowID": "\(windowID)",
            "displayUUID": "\(displayUUID)",
            "targetSpaceID": "\(targetSpace.id)"
        ])

        // First, move the window to a space on that display
        if !moveWindowToSpace(windowID: windowID, spaceID: targetSpace.id) {
            return false
        }

        // If a position was specified, set it
        if let position = position {
            // Get the window from state to find its PID
            guard let windowState = stateManager.getState().windows[String(windowID)],
                  let element = getAXElement(pid: windowState.pid, windowID: windowID) else {
                logger.error("Failed to get AX element for position update")
                return false
            }

            // Set the position
            if !setWindowPosition(element: element, point: position) {
                logger.warning("Window moved to display but position update failed")
                return false
            }
        }

        logger.debug("Window moved to display", metadata: [
            "windowID": "\(windowID)",
            "display": "\(displayUUID)"
        ])

        // Re-query space assignment after successful move
        stateManager.updateWindowSpacesPublic(windowID)

        return true
    }
}

// External C function for getting window ID from AX element
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<UInt32>) -> AXError
