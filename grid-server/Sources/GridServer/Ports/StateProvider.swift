//
// StateProvider.swift
// GridServer
//
// Port protocol for state queries. Consumers depend on this abstraction
// instead of the concrete StateManager actor, enabling test fakes.
//

import Foundation

// AnyObject: consumers hold weak references.
// Sendable: used across actor boundaries (StateManager is an actor).
protocol StateProvider: AnyObject, Sendable {
    func getState() async -> WindowManagerState

    // Re-query a single window's AX properties (role/subrole/buttons/modal),
    // update the cached WindowState, and return the refreshed value. Returns
    // nil when the window is no longer tracked or its AX element is
    // unresolvable. Lets a consumer re-classify against live AX state instead
    // of a stale snapshot (#41 Chrome torn-tab grace rescue).
    func refreshWindowAXProperties(_ windowID: UInt32) async -> WindowState?
}
