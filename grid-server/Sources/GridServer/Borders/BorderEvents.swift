//
// BorderEvents.swift
// GridServer
//
// Routes StateManager events to SimpleBorderManager
//

import Foundation
import CoreGraphics

/// Routes window events from StateManager to SimpleBorderManager
///
/// **Thread Safety**: All methods must be called on the main queue.
/// The weak references to managers are not thread-safe.
class BorderEvents: StateEventHandler {
    private weak var simpleBorderManager: SimpleBorderManager?

    init() {}

    /// Connect to managers
    func setup(simpleBorderManager: SimpleBorderManager) {
        self.simpleBorderManager = simpleBorderManager

        Task {
            JSONLogger.shared.log("bdr.events.init", data: [:])
            await EventRouter.shared.register(self)
        }
    }

    // MARK: - StateEventHandler Protocol

    func handle(_ event: StateEvent, context: EventContext) async throws {
        // [OBERDEBUG-001] Entry point
        JSONLogger.shared.log("dbg.bdr.handle_entry", data: [
            "event": String(describing: event).prefix(50),
            "source": context.source.description
        ])

        // Allow focusChanged from CLI commands (cli-focus), filter other manual events
        if case .manual(let reason) = context.source, reason != "cli-focus" { return }

        // [OBERDEBUG-002] Passed filter
        JSONLogger.shared.log("dbg.bdr.passed_filter", data: [
            "event": String(describing: event).prefix(50),
            "source": context.source.description
        ])

        switch event {
        case .windowDestroyed(let windowID):
            simpleBorderManager?.handleWindowDestroyed(windowID: windowID)

        case .windowMoved(let windowID, let frame):
            simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)

        case .windowResized(let windowID, let frame):
            simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)

        case .focusChanged(let state):
            // [OBERDEBUG-003] focusChanged received
            JSONLogger.shared.log("dbg.bdr.focus_received", data: [
                "wid": state.windowID ?? 0,
                "source": context.source.description,
                "hasManager": simpleBorderManager != nil
            ])
            if let windowID = state.windowID {
                simpleBorderManager?.updateFocus(newFocusedWindow: windowID)
            }

        case .displayDisconnected(let displayUUID):
            simpleBorderManager?.handleDisplayDisconnected(displayUUID: displayUUID)

        default:
            break
        }
    }
}
