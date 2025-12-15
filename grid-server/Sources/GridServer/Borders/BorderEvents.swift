//
// BorderEvents.swift
// GridServer
//
// Routes StateManager events to BorderManager
//

import Foundation
import CoreGraphics
import Logging

/// Routes window events from StateManager to BorderManager and SimpleBorderManager
///
/// **Thread Safety**: All methods must be called on the main queue.
/// The weak references to managers are not thread-safe.
class BorderEvents {
    private let logger = Logger(label: "com.grid.BorderEvents")
    private weak var borderManager: BorderManager?
    private weak var simpleBorderManager: SimpleBorderManager?
    private weak var stateManager: StateManager?

    init() {}

    /// Connect to managers (legacy BorderManager path)
    func setup(borderManager: BorderManager, stateManager: StateManager) {
        self.borderManager = borderManager
        self.stateManager = stateManager

        // Set up callback for BorderManager to query bundle ID
        borderManager.getBundleIDForWindow = { [weak self] windowID in
            self?.getBundleIDForWindow(windowID)
        }

        logger.info("BorderEvents connected to managers (legacy)")
    }

    /// Connect to managers (SimpleBorderManager path)
    func setup(simpleBorderManager: SimpleBorderManager, stateManager: StateManager) {
        self.simpleBorderManager = simpleBorderManager
        self.stateManager = stateManager

        logger.info("BorderEvents connected to SimpleBorderManager")
    }

    // MARK: - Event Handlers (called by StateManager)

    /// Handle window creation with bundleID passed directly to avoid re-entrant StateManager calls
    func handleWindowCreated(_ windowID: UInt32, bundleID: String?) {
        borderManager?.createBorder(for: windowID, bundleID: bundleID)
    }

    func handleWindowDestroyed(_ windowID: UInt32) {
        // Legacy path
        borderManager?.destroyBorder(for: windowID)

        // SimpleBorderManager path
        simpleBorderManager?.handleWindowDestroyed(windowID: windowID)
    }

    func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        // Legacy path
        borderManager?.updatePosition(for: windowID, frame: frame)

        // SimpleBorderManager path
        simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)
    }

    func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        // Legacy path
        borderManager?.updatePosition(for: windowID, frame: frame)

        // SimpleBorderManager path (treat resize like move)
        simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)
    }

    func handleWindowFocused(_ windowID: UInt32) {
        // Legacy path
        borderManager?.updateFocus(newFocusedWindow: windowID)

        // SimpleBorderManager path
        simpleBorderManager?.updateFocus(newFocusedWindow: windowID)
    }

    func handleWindowMinimized(_ windowID: UInt32) {
        // Legacy path
        borderManager?.hideBorder(for: windowID)

        // SimpleBorderManager path
        simpleBorderManager?.handleWindowMinimized(windowID: windowID)
    }

    func handleWindowDeminimized(_ windowID: UInt32) {
        // Legacy path
        borderManager?.showBorder(for: windowID)
        borderManager?.updateBorder(for: windowID)

        // SimpleBorderManager path
        simpleBorderManager?.handleWindowDeminimized(windowID: windowID)
    }

    func handleAppHidden(bundleID: String) {
        // Legacy path: Hide borders for all windows of this app
        guard let state = stateManager?.getState() else {
            logger.warning("State unavailable in handleAppHidden")
            return
        }

        let windows = Array(state.windows.values)  // Snapshot to avoid mutation during iteration
        for window in windows {
            if getBundleIDForWindow(window.id) == bundleID {
                borderManager?.hideBorder(for: window.id)
            }
        }

        // SimpleBorderManager path
        simpleBorderManager?.handleAppHidden(bundleID: bundleID)
    }

    func handleAppUnhidden(bundleID: String) {
        // Legacy path: Show borders for all windows of this app
        guard let state = stateManager?.getState() else {
            logger.warning("State unavailable in handleAppUnhidden")
            return
        }

        let windows = Array(state.windows.values)  // Snapshot to avoid mutation during iteration
        for window in windows {
            if getBundleIDForWindow(window.id) == bundleID {
                borderManager?.showBorder(for: window.id)
                borderManager?.updateBorder(for: window.id)
            }
        }

        // SimpleBorderManager path
        simpleBorderManager?.handleAppUnhidden(bundleID: bundleID)
    }

    func handleSpaceChanged() {
        // Legacy path: Refresh all borders for current space visibility
        // Windows not on current space will have their borders hidden by the system
        guard let state = stateManager?.getState() else {
            logger.warning("State unavailable in handleSpaceChanged")
            return
        }

        let windows = Array(state.windows.values)  // Snapshot to avoid mutation during iteration
        for window in windows {
            borderManager?.updateBorder(for: window.id)
        }

        // SimpleBorderManager path
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
