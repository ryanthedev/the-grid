//
// GridStorage.swift
// GridServer
//
// Port protocol for state persistence. GridState holds any GridStorage and
// delegates load/save to it, enabling test fakes with no file system access.
//

import Foundation

// Sendable: passed across actor boundaries (GridState init from non-actor context).
// Not AnyObject: allows struct conformers; GridState owns its storage strongly.
protocol GridStorage: Sendable {

    // Load persisted state from storage.
    // Returns nil if no prior state exists (first run / clean slate).
    // Throws on I/O or decoding failure.
    func load() async throws -> GridRuntimeStateData?

    // Persist current state to storage.
    // Throws on I/O or encoding failure.
    func save(_ data: GridRuntimeStateData) async throws
}
