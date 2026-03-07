//
// PickerModels.swift
// GridServer
//
// Data models for the picker UI
//

import Foundation

// MARK: - PickerItem

/// A single item that can be displayed and selected in the picker
struct PickerItem: Codable, Equatable {
    /// Unique identifier for this item
    let id: String

    /// Primary text shown in the picker (required)
    let title: String

    /// Secondary line (path, description)
    let subtitle: String?

    /// Third line excerpt
    let preview: String?

    /// Icon value (emoji, file path, data:base64, or inline SVG)
    let icon: String?

    /// Additional strings to search against (e.g., description, path, tags)
    let searchable: [String]

    /// Optional metadata passed back on selection (picker ignores this)
    let metadata: [String: String]?

    /// Priority for sorting (higher = appears first when match scores are equal)
    let priority: Int

    /// Display text shown in the picker (backwards compatibility, returns title)
    var display: String {
        title
    }

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        preview: String? = nil,
        icon: String? = nil,
        searchable: [String]? = nil,
        metadata: [String: String]? = nil,
        priority: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.icon = icon
        self.searchable = searchable ?? [title]
        self.metadata = metadata
        self.priority = priority
    }

    /// Custom Decodable init to handle both old format (display) and new format (title + optional fields)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        // Backwards compatibility: prefer title, fallback to display
        if let titleValue = try container.decodeIfPresent(String.self, forKey: .title) {
            title = titleValue
        } else {
            title = try container.decode(String.self, forKey: .display)
        }

        // New optional fields
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)

        // Existing optional fields
        let optionalSearchable = try container.decodeIfPresent([String].self, forKey: .searchable)
        searchable = optionalSearchable ?? [title]
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    /// Custom Encodable to include display field for backwards compatibility
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        // Include display for backwards compatibility
        try container.encode(title, forKey: .display)
        try container.encode(searchable, forKey: .searchable)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(priority, forKey: .priority)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, display, subtitle, preview, icon, searchable, metadata, priority
    }

    /// Get all searchable text (title + searchable + subtitle + preview when present)
    var allSearchableText: [String] {
        var texts = [title] + searchable
        if let subtitle = subtitle {
            texts.append(subtitle)
        }
        if let preview = preview {
            texts.append(preview)
        }
        return texts
    }
}

// MARK: - MatchResult

/// Result of matching a query against an item
struct MatchResult {
    /// The matched item
    let item: PickerItem

    /// Match score (higher = better match)
    let score: Int

    /// Indices of matched characters in the display string (for highlighting)
    let matchedIndices: [Int]
}

// MARK: - PickerAction

/// Action to perform when an item is selected
enum PickerAction {
    case focusWindow(pid: pid_t, windowID: UInt32)
    case openApp(bundleID: String)

    /// Parse from PickerItem.metadata dictionary
    /// Convention: metadata["action"] = "focusWindow", metadata["pid"] = "123", metadata["windowID"] = "456"
    static func from(metadata: [String: String]?) -> PickerAction? {
        guard let meta = metadata, let action = meta["action"] else { return nil }
        switch action {
        case "focusWindow":
            guard let pidStr = meta["pid"], let pid = Int32(pidStr),
                  let widStr = meta["windowID"], let wid = UInt32(widStr) else { return nil }
            return .focusWindow(pid: pid, windowID: wid)
        case "openApp":
            guard let bundleID = meta["bundleID"] else { return nil }
            return .openApp(bundleID: bundleID)
        default:
            return nil
        }
    }
}

// MARK: - PickerResult

/// Simplified result enum — server handles actions directly (no JSON output, no exit codes)
enum PickerResult {
    case selected(PickerItem)
    case cancelled
}
