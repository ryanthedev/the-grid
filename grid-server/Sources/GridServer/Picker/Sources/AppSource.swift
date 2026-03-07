//
// AppSource.swift
// GridServer
//
// PickerSource that scans /Applications etc for .app bundles.
// Port of Go DiscoverApps().
//

import Foundation

/// Discovers installed applications by scanning standard macOS app directories
struct AppSource: PickerSource {
    let id = "apps"

    func discover() async throws -> [PickerItem] {
        let home = NSHomeDirectory()
        let dirs = [
            "/Applications",
            "/System/Applications",
            home + "/Applications"
        ]

        // Track seen bundle IDs to dedup across directories
        var seen = Set<String>()
        var items: [PickerItem] = []

        for dir in dirs {
            let dirItems = scanAppDir(dir, seen: &seen)
            items.append(contentsOf: dirItems)
        }

        // Sort by title for consistent initial ordering
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return items
    }

    // MARK: - Private

    private func scanAppDir(_ dir: String, seen: inout Set<String>) -> [PickerItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            // Directory might not exist (e.g., ~/Applications)
            return []
        }

        var items: [PickerItem] = []

        for entry in entries {
            guard entry.hasSuffix(".app") else { continue }

            let appPath = (dir as NSString).appendingPathComponent(entry)
            if let item = parseAppBundle(appPath: appPath, seen: &seen) {
                items.append(item)
            }
        }

        return items
    }

    private func parseAppBundle(appPath: String, seen: inout Set<String>) -> PickerItem? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")

        // Read and decode plist using PropertyListSerialization
        guard let plistData = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            return nil
        }

        // Extract bundle identifier
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            return nil
        }

        // Skip if already seen
        guard !seen.contains(bundleID) else { return nil }
        seen.insert(bundleID)

        // Determine display name: DisplayName -> BundleName -> filename without .app
        let displayName = plist["CFBundleDisplayName"] as? String
        let bundleName = plist["CFBundleName"] as? String
        let fallbackName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = displayName ?? bundleName ?? fallbackName

        return PickerItem(
            id: "app:" + bundleID,
            title: name,
            subtitle: bundleID,
            icon: "bundle:" + bundleID,
            searchable: [name.lowercased(), bundleID.lowercased()],
            metadata: [
                "action": "openApp",
                "bundleID": bundleID,
                "appPath": appPath
            ],
            priority: 100
        )
    }
}
