//
// PickerSource.swift
// GridServer
//
// Protocol for picker data sources
//

import Foundation

/// A source of items for the picker
/// Sources run concurrently in a TaskGroup — each delivers a batch of items
protocol PickerSource {
    /// Unique identifier for this source (used in logging)
    var id: String { get }

    /// Discover items from this source
    /// Called from a TaskGroup — may run concurrently with other sources
    func discover() async throws -> [PickerItem]
}
