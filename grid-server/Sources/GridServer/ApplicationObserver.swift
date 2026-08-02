//
// ApplicationObserver.swift
// GridServer
//
// Manages AX observer for one application's window events
//

import Foundation
import ApplicationServices

/// Manages AX accessibility observer for a single application
class ApplicationObserver {
    let pid: pid_t
    let appName: String?
    private var observer: AXObserver?
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
            Task {
                JSONLogger.shared.log("ax.fail", data: [
                    "op": "create_observer",
                    "pid": pid,
                    "app": appName ?? "unknown",
                    "err": error.rawValue
                ])
            }
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
                Task {
                    JSONLogger.shared.log("ax.fail", data: [
                        "op": "register_notif",
                        "notif": notification as String,
                        "err": result.rawValue
                    ])
                }
            }
        }

        guard successCount > 0 else {
            Task {
                JSONLogger.shared.log("ax.fail", data: [
                    "op": "register_notifs",
                    "msg": "no notifications registered"
                ])
            }
            return false
        }

        // Add observer to main run loop
        let runLoopSource = AXObserverGetRunLoopSource(observerRef)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        Task {
            JSONLogger.shared.log("ax.observer.create", data: [
                "pid": pid,
                "app": appName ?? "?",
                "notifs": "\(successCount)/\(Self.observedNotifications.count)"
            ])
        }

        return true
    }

    /// Stop observing (cleanup)
    func stopObserving() {
        guard let observer = observer else { return }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        self.observer = nil

        Task {
            JSONLogger.shared.log("ax.observer.stop", data: [
                "pid": pid,
                "app": appName ?? "unknown"
            ])
        }
    }

    /// Handle AX notification callback
    func handleNotification(element: AXUIElement, notification: CFString, seq: UInt64 = 0) async {
        let notifName = notification as String

        // For AXCreated, check element role to avoid processing non-window elements
        if notifName == kAXCreatedNotification as String {
            var roleValue: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            if roleResult == .success, let role = roleValue as? String {
                if role != "AXWindow" {
                    return
                }
            } else {
                // Can't determine role - skip to be safe
                return
            }
        }

        // For AXUIElementDestroyed, the element is already dead — can't query role.
        // Instead, try to get the window ID. If it fails, it wasn't a tracked window.
        if notifName == kAXUIElementDestroyedNotification as String {
            guard getWindowID(from: element) != nil else {
                return
            }
        }

        let source = EventSource.axObserver(pid: pid, appName: appName ?? "Unknown")

        // Handle focus notification - element is the window that gained focus
        if notifName == kAXFocusedWindowChangedNotification as String {
            // The callback element IS the focused window, get its ID directly
            guard let windowID = getWindowID(from: element) else {
                // Fallback: try querying the app element for focused window
                let appElement = AXUIElementCreateApplication(pid)
                let (focusedWindow, axError) = getFocusedWindowWithError(from: appElement)
                guard let focusedWindow = focusedWindow,
                      let fallbackWindowID = getWindowID(from: focusedWindow) else {
                    JSONLogger.shared.log("ax.fail", data: [
                        "op": "get_focused_window",
                        "notif": notifName,
                        "app": appName ?? "unknown",
                        "axErr": axError?.rawValue ?? -1
                    ])
                    return
                }
                let focusState = FocusState(
                    windowID: fallbackWindowID,
                    spaceID: 0,
                    displayUUID: "",
                    trigger: .windowActivated,
                    seq: seq
                )
                await EventRouter.shared.route(.focusChanged(focusState), from: source)
                return
            }

            let focusState = FocusState(
                windowID: windowID,
                spaceID: 0,
                displayUUID: "",
                trigger: .windowActivated,
                seq: seq
            )
            let event = StateEvent.focusChanged(focusState)
            await EventRouter.shared.route(event, from: source)
            return
        }

        // Extract window ID from AX element for other notifications
        guard let windowID = getWindowID(from: element) else {
            // Sample 1-in-N: AX events fire constantly on transient elements
            // (AXTitleChanged, AXWindowMoved, AXWindowResized) where window ID
            // resolution is expected to fail and there's nothing to act on.
            let (shouldLog, total) = Self.recordGetWindowIDFail()
            if shouldLog {
                JSONLogger.shared.log("ax.fail", data: [
                    "op": "get_window_id",
                    "notif": notifName,
                    "sampled": "1/\(Self.getWindowIDFailSampleN)",
                    "totalSeen": total
                ])
            }
            return
        }

        // Route to EventRouter based on notification type
        switch notifName {
        case kAXCreatedNotification:
            let event = StateEvent.windowCreated(windowID: windowID, pid: pid)
            await EventRouter.shared.route(event, from: source)

        case kAXUIElementDestroyedNotification:
            let event = StateEvent.windowDestroyed(windowID: windowID)
            await EventRouter.shared.route(event, from: source)

        case kAXWindowMovedNotification:
            if let frame = getWindowFrame(from: element) {
                let event = StateEvent.windowMoved(windowID: windowID, frame: frame)
                await EventRouter.shared.route(event, from: source)
            }

        case kAXWindowResizedNotification:
            if let frame = getWindowFrame(from: element) {
                let event = StateEvent.windowResized(windowID: windowID, frame: frame)
                await EventRouter.shared.route(event, from: source)
            }

        case kAXWindowMiniaturizedNotification:
            let event = StateEvent.windowMinimized(windowID: windowID)
            await EventRouter.shared.route(event, from: source)

        case kAXWindowDeminiaturizedNotification:
            let event = StateEvent.windowDeminimized(windowID: windowID)
            await EventRouter.shared.route(event, from: source)

        case kAXTitleChangedNotification:
            if let title = getWindowTitle(from: element) {
                let event = StateEvent.windowTitleChanged(windowID: windowID, title: title)
                await EventRouter.shared.route(event, from: source)
            }

        default:
            break
        }
    }

    // MARK: - AX Property Helpers

    /// Get the focused window element from an application element (with error info)
    private func getFocusedWindowWithError(from appElement: AXUIElement) -> (AXUIElement?, AXError?) {
        var focusedWindow: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard error == .success else { return (nil, error) }
        // Unwrap before downcasting: force-casting the Optional directly can
        // never yield nil, so a non-AXUIElement payload would trap. Report a
        // type mismatch as .failure rather than .success, so the caller's
        // ax.fail event is not stamped with kAXErrorSuccess.
        guard let value = focusedWindow,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, .failure)
        }
        // CFGetTypeID above is the check that licenses this; a conditional cast
        // to a CF type here is what the compiler flags as never-nil.
        return (unsafeBitCast(value, to: AXUIElement.self), nil)
    }

    // MARK: - Log Sampling

    private static let getWindowIDFailSampleN: UInt64 = 100
    private static let getWindowIDFailLock = NSLock()
    private static var getWindowIDFailCount: UInt64 = 0

    private static func recordGetWindowIDFail() -> (shouldLog: Bool, total: UInt64) {
        getWindowIDFailLock.lock()
        defer { getWindowIDFailLock.unlock() }
        getWindowIDFailCount &+= 1
        let total = getWindowIDFailCount
        return (total % getWindowIDFailSampleN == 1, total)
    }

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
    // #17: stamp the focus sequence HERE — the AX callback fires in-order on the
    // main run loop. The Task{} below can then reorder events on the global
    // executor, but the stamp preserves arrival order for the apply-side gate.
    let seq = FocusEventSequence.next()
    Task {
        await appObserver.handleNotification(element: element, notification: notification, seq: seq)
    }
}

// MARK: - Private AX API

// Private function to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError
