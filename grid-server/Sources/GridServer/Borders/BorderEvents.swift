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
class BorderEvents {
    private weak var simpleBorderManager: SimpleBorderManager?
    private weak var stateManager: StateManager?

    init() {}

    /// Connect to managers
    func setup(simpleBorderManager: SimpleBorderManager, stateManager: StateManager) {
        self.simpleBorderManager = simpleBorderManager
        self.stateManager = stateManager

        Task { await JSONLogger.shared.log("bdr.events.init", data: [:]) }
    }

    // MARK: - Event Handlers (called by StateManager)

    /// Handle window creation with bundleID passed directly to avoid re-entrant StateManager calls
    func handleWindowCreated(_ windowID: UInt32, bundleID: String?) {
        // SimpleBorderManager doesn't need per-window creation
    }

    func handleWindowDestroyed(_ windowID: UInt32) {
        simpleBorderManager?.handleWindowDestroyed(windowID: windowID)
    }

    func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)
    }

    func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)
    }

    func handleWindowFocused(_ windowID: UInt32) {
        simpleBorderManager?.updateFocus(newFocusedWindow: windowID)
    }

    // NOTE: handleWindowMinimized, handleWindowDeminimized, handleAppHidden,
    // handleAppUnhidden, and handleSpaceChanged are intentionally not routed.
    // These events trigger focus changes upstream, and BorderManager reacts
    // to the resulting focus/assignment changes instead.

    func handleDisplayDisconnected(displayUUID: String) {
        simpleBorderManager?.handleDisplayDisconnected(displayUUID: displayUUID)
    }
}
