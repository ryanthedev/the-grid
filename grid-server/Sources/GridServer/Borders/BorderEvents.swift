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
        // TEMP: Disable AX event handling - borders now sync via CLI only
        _ = (event, context)
    }
}
