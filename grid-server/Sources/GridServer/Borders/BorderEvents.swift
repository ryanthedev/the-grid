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
            await JSONLogger.shared.log("bdr.events.init", data: [:])
            await EventRouter.shared.register(self)
        }
    }

    // MARK: - StateEventHandler Protocol

    func handle(_ event: StateEvent, context: EventContext) async throws {
        if case .manual = context.source { return }

        switch event {
        case .windowDestroyed(let windowID):
            simpleBorderManager?.handleWindowDestroyed(windowID: windowID)

        case .windowMoved(let windowID, let frame):
            simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)

        case .windowResized(let windowID, let frame):
            simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)

        case .focusChanged(let state):
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
