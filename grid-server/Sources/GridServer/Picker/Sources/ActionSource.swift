//
// ActionSource.swift
// GridServer
//
// PickerSource that reads custom actions from server config.
// Port of Go DiscoverActions().
//

import Foundation

/// Discovers custom actions defined in picker config
struct ActionSource: PickerSource {
    let id = "actions"

    /// Action definitions from GridConfig.pickerActions
    let actions: [ActionDef]

    func discover() async throws -> [PickerItem] {
        // Pure transformation — no async work needed
        var items: [PickerItem] = []

        for actionDef in actions {
            // Skip invalid entries
            guard !actionDef.name.isEmpty, !actionDef.command.isEmpty else { continue }

            // Generate stable ID: "action:" + slugified name
            let slug = actionDef.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let id = "action:" + slug

            // Icon: from config, or default "terminal"
            let icon = actionDef.icon ?? "terminal"

            // Subtitle: category or "Action"
            let subtitle = actionDef.category ?? "Action"

            // Searchable: name words + category
            var searchable = [actionDef.name.lowercased()]
            if let category = actionDef.category, !category.isEmpty {
                searchable.append(category.lowercased())
            }
            // Add individual words from name
            for word in actionDef.name.split(separator: " ") {
                let lower = word.lowercased()
                if lower != searchable[0] {
                    searchable.append(lower)
                }
            }

            items.append(PickerItem(
                id: id,
                title: actionDef.name,
                subtitle: subtitle,
                icon: icon,
                searchable: searchable,
                metadata: [
                    "action": "exec",
                    "command": actionDef.command
                ],
                priority: 150
            ))
        }

        return items
    }
}
