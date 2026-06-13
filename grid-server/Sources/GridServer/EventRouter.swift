//
// EventRouter.swift
// GridServer
//
// Centralized event routing for all macOS events
//

import Foundation
import AppKit

// MARK: - Event Types

/// All state events that flow through the system
enum StateEvent {
    // Window lifecycle
    case windowCreated(windowID: UInt32, pid: pid_t)
    case windowDestroyed(windowID: UInt32)

    // Window properties
    case windowMoved(windowID: UInt32, frame: CGRect)
    case windowResized(windowID: UInt32, frame: CGRect)
    case windowMinimized(windowID: UInt32)
    case windowDeminimized(windowID: UInt32)
    case windowTitleChanged(windowID: UInt32, title: String)
    case windowSpaceAssignmentChanged(windowID: UInt32, spaces: [UInt64])

    // Unified focus (replaces windowFocused, spaceChanged activation, appActivated)
    case focusChanged(FocusState)

    // Space lifecycle
    case spaceCreated(spaceID: UInt64, displayUUID: String)
    case spaceDestroyed(spaceID: UInt64)
    // macOS reassigned a space ID on a display (e.g. fullscreen app create/destroy)
    case spaceIDReassigned(oldSpaceID: String, newSpaceID: String, displayUUID: String)
    // Plain desktop switch — the old space still exists (#2). No migration;
    // the reconciler resyncs borders for the newly-active space.
    case spaceActivated(spaceID: String, displayUUID: String)

    // Display lifecycle
    case displayConnected(displayUUID: String)
    case displayDisconnected(displayUUID: String)
    case displayReconfigured(displayUUID: String)
    // Geometry-only reconfiguration (#25): resolution/scaling/Dock change with
    // the same display UUID set. Carries the affected display; reconciler
    // reapplies layouts (debounced).
    case displayGeometryChanged(displayUUID: String)

    // App lifecycle
    case appLaunched(app: NSRunningApplication)
    case appTerminated(app: NSRunningApplication)
    case appHidden(app: NSRunningApplication)
    case appUnhidden(app: NSRunningApplication)

    // System
    case systemWoke
    case systemWillSleep
    case screenLocked
    case screenUnlocked

    // CLI commands (intent events)
    case commandFocusWindow(windowID: UInt32, requestID: String)
    case commandMoveWindow(windowID: UInt32, frame: CGRect, requestID: String)
    case commandResizeWindow(windowID: UInt32, frame: CGRect, requestID: String)
    case commandMinimizeWindow(windowID: UInt32, requestID: String)
    case commandCloseWindow(windowID: UInt32, requestID: String)
    case commandMoveWindowToSpace(windowID: UInt32, spaceID: UInt64, requestID: String)
}

// MARK: - Supporting Types

/// Represents the current focus state with history
struct FocusState {
    let windowID: UInt32?
    let spaceID: UInt64
    let displayUUID: String
    let previousWindowID: UInt32?
    let previousSpaceID: UInt64?
    let previousDisplayUUID: String?
    let trigger: FocusTrigger

    /// Convenience initializer with defaults for previous state fields
    init(
        windowID: UInt32? = nil,
        spaceID: UInt64,
        displayUUID: String,
        previousWindowID: UInt32? = nil,
        previousSpaceID: UInt64? = nil,
        previousDisplayUUID: String? = nil,
        trigger: FocusTrigger
    ) {
        self.windowID = windowID
        self.spaceID = spaceID
        self.displayUUID = displayUUID
        self.previousWindowID = previousWindowID
        self.previousSpaceID = previousSpaceID
        self.previousDisplayUUID = previousDisplayUUID
        self.trigger = trigger
    }
}

/// What caused the focus change
enum FocusTrigger {
    case windowActivated
    case spaceSwitched
    case appActivated
    case windowClosed
    case windowCreated
    case focusRestored
    case manual
}

/// Where the event originated
enum EventSource: CustomStringConvertible {
    case axObserver(pid: pid_t, appName: String?)
    case workspaceObserver
    case poll
    case manual(reason: String)

    var description: String {
        switch self {
        case .axObserver(let pid, let appName):
            return "ax(\(appName ?? String(pid)))"
        case .workspaceObserver:
            return "workspace"
        case .poll:
            return "poll"
        case .manual(let reason):
            return "manual(\(reason))"
        }
    }
}

/// Context for event routing
struct EventContext {
    let timestamp: Date
    let source: EventSource
    let traceID: String?
    let spanID: String?

    init(
        source: EventSource,
        traceID: String? = nil,
        spanID: String? = nil
    ) {
        self.timestamp = Date()
        self.source = source
        self.traceID = traceID
        self.spanID = spanID
    }
}

// MARK: - Handler Protocol

/// Protocol for components that handle state events
protocol StateEventHandler: AnyObject {
    func handle(_ event: StateEvent, context: EventContext) async throws
}

// MARK: - Event Router

/// Central router for all state events
///
/// **Thread Safety**: All event routing happens on a serial queue.
/// Handlers are stored weakly to avoid retain cycles.
actor EventRouter {
    static let shared = EventRouter()

    private var handlers: [WeakHandler] = []

    private init() {}

    /// Register a handler to receive events
    func register(_ handler: StateEventHandler) {
        // Remove any stale references first
        handlers.removeAll { $0.handler == nil }

        // Add new handler
        handlers.append(WeakHandler(handler))

        Task {
            JSONLogger.shared.log("router.register", data: [
                "handler": String(describing: type(of: handler)),
                "count": handlers.count
            ])
        }
    }

    /// Unregister a handler
    func unregister(_ handler: StateEventHandler) {
        handlers.removeAll { $0.handler === handler || $0.handler == nil }

        Task {
            JSONLogger.shared.log("router.unregister", data: [
                "handler": String(describing: type(of: handler)),
                "count": handlers.count
            ])
        }
    }

    /// Route an event to all registered handlers
    func route(_ event: StateEvent, context: EventContext) async {
        // Log the event
        await logEvent(event, context: context)

        // Remove stale handlers
        handlers.removeAll { $0.handler == nil }

        // Dispatch to all handlers
        for weakHandler in handlers {
            if let handler = weakHandler.handler {
                do {
                    try await handler.handle(event, context: context)
                } catch {
                    JSONLogger.shared.log("router.err", msg: "handler error", data: [
                        "handler": String(describing: type(of: handler)),
                        "event": event.logInfo.0,
                        "error": String(describing: error)
                    ])
                }
            }
        }
    }

    /// Convenience method with default context
    func route(_ event: StateEvent, from source: EventSource) async {
        let context = EventContext(source: source)
        await route(event, context: context)
    }

    // MARK: - Logging

    private func logEvent(_ event: StateEvent, context: EventContext) async {
        // Skip noisy events that don't provide diagnostic value
        if case .windowTitleChanged = event { return }

        let (eventName, data) = event.logInfo
        var logData = data
        logData["src"] = context.source.description

        if let tid = context.traceID {
            logData["tid"] = tid
        }

        JSONLogger.shared.log(eventName, data: logData)
    }
}

// MARK: - Weak Handler Wrapper

private class WeakHandler {
    weak var handler: StateEventHandler?

    init(_ handler: StateEventHandler) {
        self.handler = handler
    }
}

// MARK: - Event Logging Extension

extension StateEvent {
    /// Returns event name and data for logging
    var logInfo: (String, [String: Any]) {
        switch self {
        // Window lifecycle
        case .windowCreated(let windowID, let pid):
            return ("ev.win.create", ["wid": windowID, "pid": pid])

        case .windowDestroyed(let windowID):
            return ("ev.win.destroy", ["wid": windowID])

        // Window properties
        case .windowMoved(let windowID, let frame):
            return ("ev.win.move", [
                "wid": windowID,
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            ])

        case .windowResized(let windowID, let frame):
            return ("ev.win.resize", [
                "wid": windowID,
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            ])

        case .windowMinimized(let windowID):
            return ("ev.win.min", ["wid": windowID])

        case .windowDeminimized(let windowID):
            return ("ev.win.unmin", ["wid": windowID])

        case .windowTitleChanged(let windowID, let title):
            return ("ev.win.title", ["wid": windowID, "title": title])

        case .windowSpaceAssignmentChanged(let windowID, let spaces):
            return ("ev.win.spaces", ["wid": windowID, "spaces": spaces])

        // Focus - only log what we actually know at raw event time
        // Display/space are resolved later by StateManager and logged in win.focus
        case .focusChanged(let state):
            return ("ev.focus", [
                "wid": state.windowID ?? 0,
                "trigger": String(describing: state.trigger)
            ])

        // Space lifecycle
        case .spaceCreated(let spaceID, let displayUUID):
            return ("ev.spc.create", ["sid": spaceID, "display": displayUUID])

        case .spaceDestroyed(let spaceID):
            return ("ev.spc.destroy", ["sid": spaceID])

        case .spaceIDReassigned(let oldSpaceID, let newSpaceID, let displayUUID):
            return ("ev.spc.reassign", [
                "old": oldSpaceID,
                "new": newSpaceID,
                "display": displayUUID
            ])

        case .spaceActivated(let spaceID, let displayUUID):
            return ("ev.spc.activate", ["sid": spaceID, "display": displayUUID])

        // Display lifecycle
        case .displayConnected(let displayUUID):
            return ("ev.dsp.connect", ["display": displayUUID])

        case .displayDisconnected(let displayUUID):
            return ("ev.dsp.disconnect", ["display": displayUUID])

        case .displayReconfigured(let displayUUID):
            return ("ev.dsp.reconfig", ["display": displayUUID])

        case .displayGeometryChanged(let displayUUID):
            return ("ev.dsp.geometry", ["display": displayUUID])

        // App lifecycle
        case .appLaunched(let app):
            return ("ev.app.launch", [
                "pid": app.processIdentifier,
                "app": app.localizedName ?? "unknown",
                "bundle": app.bundleIdentifier ?? "unknown"
            ])

        case .appTerminated(let app):
            return ("ev.app.term", [
                "pid": app.processIdentifier,
                "app": app.localizedName ?? "unknown"
            ])

        case .appHidden(let app):
            return ("ev.app.hide", [
                "pid": app.processIdentifier,
                "app": app.localizedName ?? "unknown"
            ])

        case .appUnhidden(let app):
            return ("ev.app.unhide", [
                "pid": app.processIdentifier,
                "app": app.localizedName ?? "unknown"
            ])

        // System
        case .systemWoke:
            return ("ev.sys.wake", [:])

        case .systemWillSleep:
            return ("ev.sys.willsleep", [:])

        case .screenLocked:
            return ("ev.sys.lock", [:])

        case .screenUnlocked:
            return ("ev.sys.unlock", [:])

        // CLI commands
        case .commandFocusWindow(let windowID, let requestID):
            return ("ev.cmd.focus", ["wid": windowID, "req": requestID])

        case .commandMoveWindow(let windowID, let frame, let requestID):
            return ("ev.cmd.move", [
                "wid": windowID,
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
                "req": requestID
            ])

        case .commandResizeWindow(let windowID, let frame, let requestID):
            return ("ev.cmd.resize", [
                "wid": windowID,
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
                "req": requestID
            ])

        case .commandMinimizeWindow(let windowID, let requestID):
            return ("ev.cmd.min", ["wid": windowID, "req": requestID])

        case .commandCloseWindow(let windowID, let requestID):
            return ("ev.cmd.close", ["wid": windowID, "req": requestID])

        case .commandMoveWindowToSpace(let windowID, let spaceID, let requestID):
            return ("ev.cmd.space", ["wid": windowID, "sid": spaceID, "req": requestID])
        }
    }
}
