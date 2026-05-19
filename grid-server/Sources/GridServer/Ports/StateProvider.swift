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
}
