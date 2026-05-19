//
// BorderRendering.swift
// GridServer
//
// Port protocol for border rendering. Consumers depend on this abstraction
// instead of the concrete SimpleBorderManager class, enabling test fakes.
//

import Foundation
import CoreGraphics

// AnyObject: consumers hold weak references.
// Sendable: used across actor boundaries (dispatches to main queue internally).
protocol BorderRendering: AnyObject, Sendable {

    // Set cell assignments for a display. Replaces the completion-callback
    // pattern with async -- the conformance bridges DispatchQueue.main
    // internally via withCheckedContinuation.
    func setCellAssignments(
        _ assignments: [UInt32: String],
        forDisplay displayUUID: String,
        focusedWindowID: UInt32?,
        cellStackModes: [String: String],
        windowOrder: [String: [UInt32]]?,
        displayFrame: CGRect?,
        source: String,
        liveWids: [UInt32]?
    ) async

    // Update focus when a different window becomes active.
    func updateFocus(newFocusedWindow: UInt32, displayUUID: String) async

    // Handle window destroyed (remove border for destroyed window).
    func handleWindowDestroyed(windowID: UInt32) async

    // Handle window moved (update border position).
    func handleWindowMoved(windowID: UInt32, newFrame: CGRect) async

    // Handle display disconnected (clean up display-specific state).
    func handleDisplayDisconnected(displayUUID: String) async
}
