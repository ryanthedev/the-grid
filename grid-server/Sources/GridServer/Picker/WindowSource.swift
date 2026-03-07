//
// WindowSource.swift
// GridServer
//
// PickerSource that reads windows from StateManager
//

import Foundation

/// Reads windows from StateManager and builds PickerItems for the picker
struct WindowSource: PickerSource {
    let id = "windows"

    func discover() async throws -> [PickerItem] {
        let state = await StateManager.shared.getState()

        var items: [PickerItem] = []

        for (windowIDStr, window) in state.windows {
            // Skip hidden and minimized windows
            guard !window.isHidden, !window.isMinimized else { continue }

            // Skip windows with alpha near zero (invisible)
            guard window.alpha > 0.01 else { continue }

            // Skip non-standard windows (popups, menus, sheets, etc.)
            // Only include AXStandardWindow subrole, or nil subrole (some apps don't set it)
            if let subrole = window.subrole, subrole != "AXStandardWindow" {
                continue
            }

            // Look up application info
            let pidStr = "\(window.pid)"
            let app = state.applications[pidStr]
            let appName = window.appName ?? app?.localizedName ?? "Unknown"
            let bundleID = app?.bundleIdentifier

            // Build title: "AppName — Window Title" or just "AppName" if no distinct title
            let title: String
            if let windowTitle = window.title, !windowTitle.isEmpty, windowTitle != appName {
                title = "\(appName) — \(windowTitle)"
            } else {
                title = appName
            }

            // Icon from bundle ID (IconRenderer handles "bundle:" prefix)
            let icon: String? = bundleID.map { "bundle:\($0)" }

            // Searchable: app name + window title + bundle ID
            var searchable = [appName]
            if let windowTitle = window.title, !windowTitle.isEmpty {
                searchable.append(windowTitle)
            }
            if let bid = bundleID {
                searchable.append(bid)
            }

            // Metadata for PickerAction.focusWindow
            var metadata: [String: String] = [
                "action": "focusWindow",
                "pid": "\(window.pid)",
                "windowID": windowIDStr
            ]
            if let bid = bundleID {
                metadata["bundleID"] = bid
            }

            let item = PickerItem(
                id: "win-\(windowIDStr)",
                title: title,
                subtitle: bundleID,
                icon: icon,
                searchable: searchable,
                metadata: metadata,
                // Windows get high priority so they appear above other sources
                priority: 1000
            )

            items.append(item)
        }

        // Sort by title for consistent ordering
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return items
    }
}
