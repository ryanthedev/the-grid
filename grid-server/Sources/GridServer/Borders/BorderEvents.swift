//
// BorderEvents.swift
// GridServer
//
// Routes StateManager events to SimpleBorderManager
//

import Foundation
import CoreGraphics
import Logging

/// Routes window events from StateManager to SimpleBorderManager
///
/// **Thread Safety**: All methods must be called on the main queue.
/// The weak references to managers are not thread-safe.
class BorderEvents {
    private let logger = Logger(label: "com.grid.BorderEvents")
    private weak var simpleBorderManager: SimpleBorderManager?
    private weak var stateManager: StateManager?

    init() {}

    /// Connect to managers
    func setup(simpleBorderManager: SimpleBorderManager, stateManager: StateManager) {
        self.simpleBorderManager = simpleBorderManager
        self.stateManager = stateManager

        logger.info("BorderEvents connected to SimpleBorderManager")
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

    func handleWindowMinimized(_ windowID: UInt32) {
        simpleBorderManager?.handleWindowMinimized(windowID: windowID)
    }

    func handleWindowDeminimized(_ windowID: UInt32) {
        simpleBorderManager?.handleWindowDeminimized(windowID: windowID)
    }

    func handleAppHidden(bundleID: String) {
        simpleBorderManager?.handleAppHidden(bundleID: bundleID)
    }

    func handleAppUnhidden(bundleID: String) {
        simpleBorderManager?.handleAppUnhidden(bundleID: bundleID)
    }

    func handleSpaceChanged() {
        simpleBorderManager?.handleSpaceChanged()
    }

    // MARK: - State Queries

    private func getBundleIDForWindow(_ windowID: UInt32) -> String? {
        guard let state = stateManager?.getState() else { return nil }
        guard let window = state.windows[String(windowID)] else { return nil }

        // Get application for this window's PID
        let pidKey = String(window.pid)
        return state.applications[pidKey]?.bundleIdentifier
    }
}
