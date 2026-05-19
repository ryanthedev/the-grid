//
// WindowController.swift
// GridServer
//
// Port protocol for window manipulation. Consumers depend on this abstraction
// instead of the concrete WindowManipulator class, enabling test fakes.
//

import Foundation
import CoreGraphics

// AnyObject: consumers hold weak references.
// Sendable: used across actor boundaries.
protocol WindowController: AnyObject, Sendable {

    // Focus a window by raising it and activating its app.
    // Returns true if the focus operation was attempted (mirrors WindowManipulator.focusWindow).
    func focusWindow(windowID: UInt32, pid: pid_t) async -> Bool

    // Set a window's frame via AX API.
    // Returns true if the frame was applied successfully.
    func setWindowFrame(windowID: UInt32, pid: pid_t, frame: CGRect) async -> Bool
}
