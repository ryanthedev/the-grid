//
// PickerItem.swift
// GridServer
//
// Data model for picker items
//

import Foundation

/// A single item that can be displayed and selected in the picker
struct PickerItem: Codable, Equatable {
    /// Unique identifier for this item
    let id: String

    /// Display text shown in the picker
    let display: String

    /// Additional strings to search against (e.g., description, path, tags)
    let searchable: [String]

    /// Optional metadata passed back on selection (picker ignores this)
    let metadata: [String: String]?

    init(id: String, display: String, searchable: [String]? = nil, metadata: [String: String]? = nil) {
        self.id = id
        self.display = display
        self.searchable = searchable ?? [display]
        self.metadata = metadata
    }

    /// Get all searchable text (display + searchable fields)
    var allSearchableText: [String] {
        [display] + searchable
    }
}

/// Result of the picker operation
enum PickerResult {
    /// User selected an item
    case selected(PickerItem)

    /// User cancelled (Escape)
    case cancelled

    /// Convert to a response-friendly dictionary
    var asDictionary: [String: Any] {
        switch self {
        case .selected(let item):
            var dict: [String: Any] = [
                "cancelled": false,
                "selected": [
                    "id": item.id,
                    "display": item.display,
                    "searchable": item.searchable
                ]
            ]
            if let metadata = item.metadata,
               var selectedDict = dict["selected"] as? [String: Any] {
                selectedDict["metadata"] = metadata
                dict["selected"] = selectedDict
            }
            return dict
        case .cancelled:
            return ["cancelled": true, "selected": NSNull()]
        }
    }
}
