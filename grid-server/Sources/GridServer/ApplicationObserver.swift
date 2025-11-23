//
// ApplicationObserver.swift
// GridServer
//
// Manages AX observer for one application's window events
//

import Foundation
import ApplicationServices
import Logging

/// Manages AX accessibility observer for a single application
class ApplicationObserver {
    let pid: pid_t
    let appName: String?
    private var observer: AXObserver?
    private let logger = Logger(label: "com.grid.ApplicationObserver")
    weak var stateManager: StateManager?

    // Notification types we observe
    private static let observedNotifications: [CFString] = [
        kAXCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXTitleChangedNotification as CFString
    ]

    init(pid: pid_t, appName: String? = nil) {
        self.pid = pid
        self.appName = appName ?? "Unknown"
    }

    /// Start observing this application's windows
    func observe(stateManager: StateManager) -> Bool {
        self.stateManager = stateManager

        // Create AX observer for this PID
        var observerRef: AXObserver?
        let error = AXObserverCreate(pid, axNotificationCallback, &observerRef)

        guard error == .success, let observerRef = observerRef else {
            logger.warning("Failed to create AX observer", metadata: [
                "pid": "\(pid)",
                "app": "\(appName ?? "unknown")",
                "error": "\(error.rawValue)"
            ])
            return false
        }

        self.observer = observerRef

        // Get application AX element
        let appElement = AXUIElementCreateApplication(pid)

        // Register for each notification type
        let context = Unmanaged.passUnretained(self).toOpaque()
        var successCount = 0

        for notification in Self.observedNotifications {
            let result = AXObserverAddNotification(
                observerRef,
                appElement,
                notification,
                context
            )

            if result == .success {
                successCount += 1
            } else {
                logger.debug("Failed to register notification", metadata: [
                    "notification": "\(notification)",
                    "error": "\(result.rawValue)"
                ])
            }
        }

        guard successCount > 0 else {
            logger.warning("No notifications registered successfully")
            return false
        }

        // Add observer to main run loop
        let runLoopSource = AXObserverGetRunLoopSource(observerRef)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        logger.info("✓ AX observer created", metadata: [
            "pid": "\(pid)",
            "app": "\(appName ?? "unknown")",
            "notifications": "\(successCount)/\(Self.observedNotifications.count)"
        ])

        return true
    }

    /// Stop observing (cleanup)
    func stopObserving() {
        guard let observer = observer else { return }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        self.observer = nil

        logger.debug("AX observer stopped", metadata: [
            "pid": "\(pid)",
            "app": "\(appName ?? "unknown")"
        ])
    }

    /// Handle AX notification callback
    func handleNotification(element: AXUIElement, notification: CFString) {
        let notifName = notification as String

        // Extract window ID from AX element
        guard let windowID = getWindowID(from: element) else {
            logger.debug("Could not get window ID from AX element", metadata: [
                "notification": "\(notifName)"
            ])
            return
        }

        logger.debug("AX notification received", metadata: [
            "notification": "\(notifName)",
            "windowID": "\(windowID)",
            "pid": "\(pid)"
        ])

        // Route to appropriate handler based on notification type
        switch notifName {
        case kAXCreatedNotification as String:
            stateManager?.handleWindowCreated(windowID, pid: pid)

        case kAXUIElementDestroyedNotification as String:
            stateManager?.handleWindowDestroyed(windowID)

        case kAXFocusedWindowChangedNotification as String:
            stateManager?.handleWindowFocused(windowID)

        case kAXWindowMovedNotification as String:
            if let frame = getWindowFrame(from: element) {
                stateManager?.handleWindowMoved(windowID, frame: frame)
            }

        case kAXWindowResizedNotification as String:
            if let frame = getWindowFrame(from: element) {
                stateManager?.handleWindowResized(windowID, frame: frame)
            }

        case kAXWindowMiniaturizedNotification as String:
            stateManager?.handleWindowMinimized(windowID)

        case kAXWindowDeminiaturizedNotification as String:
            stateManager?.handleWindowDeminimized(windowID)

        case kAXTitleChangedNotification as String:
            if let title = getWindowTitle(from: element) {
                stateManager?.handleWindowTitleChanged(windowID, title: title)
            }

        default:
            logger.debug("Unknown notification type", metadata: ["notification": "\(notifName)"])
        }
    }

    // MARK: - AX Property Helpers

    private func getWindowID(from element: AXUIElement) -> UInt32? {
        var windowID: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowID)

        if error == .success, let id = windowID as? UInt32 {
            return id
        }

        // Fallback: try to get CGWindowID
        var cgWindowID: UInt32 = 0
        let result = _AXUIElementGetWindow(element, &cgWindowID)

        return result == .success ? cgWindowID : nil
    }

    private func getWindowFrame(from element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let posValue = position,
              let sizeValue = size else {
            return nil
        }

        var point = CGPoint.zero
        var dimensions = CGSize.zero

        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &dimensions) else {
            return nil
        }

        return CGRect(origin: point, size: dimensions)
    }

    private func getWindowTitle(from element: AXUIElement) -> String? {
        var title: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)

        return error == .success ? (title as? String) : nil
    }
}

// MARK: - Global AX Callback Function

private func axNotificationCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) -> Void {
    guard let refcon = refcon else {
        print("[ERROR] AX callback: refcon is nil")
        return
    }

    let appObserver = Unmanaged<ApplicationObserver>.fromOpaque(refcon).takeUnretainedValue()
    appObserver.handleNotification(element: element, notification: notification)
}

// MARK: - Private AX API

// Private function to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError
