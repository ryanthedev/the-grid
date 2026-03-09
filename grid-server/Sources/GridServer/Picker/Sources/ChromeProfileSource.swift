//
// ChromeProfileSource.swift
// GridServer
//
// PickerSource that reads Chrome Local State for profile discovery.
// Port of Go DiscoverChromeProfiles().
//

import Foundation

/// Discovers Chrome browser profiles from Local State JSON
struct ChromeProfileSource: PickerSource {
    let id = "chrome"

    func discover() async throws -> [PickerItem] {
        let home = NSHomeDirectory()
        let localStatePath = home + "/Library/Application Support/Google/Chrome/Local State"

        // Read file — if Chrome not installed, return empty (not an error)
        guard let data = FileManager.default.contents(atPath: localStatePath) else {
            return []
        }

        // Parse JSON structure: { "profile": { "info_cache": { "Profile 1": {...}, ... } } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: [String: Any]] else {
            return []
        }

        var items: [PickerItem] = []

        for (profileDir, profileInfo) in infoCache {
            // Extract profile fields
            let profileName = profileInfo["name"] as? String ?? ""
            let gaiaName = profileInfo["gaia_name"] as? String ?? ""
            let shortcutName = profileInfo["shortcut_name"] as? String ?? ""
            let userName = profileInfo["user_name"] as? String ?? ""
            let isUsingDefault = profileInfo["is_using_default_name"] as? Bool ?? false

            // Determine best display name
            // Priority: name (if not default) -> gaiaName -> shortcutName -> userName -> profileDir
            let name: String
            if !profileName.isEmpty && !isUsingDefault {
                name = profileName
            } else if !gaiaName.isEmpty {
                name = gaiaName
            } else if !shortcutName.isEmpty {
                name = shortcutName
            } else if !userName.isEmpty {
                name = userName
            } else {
                name = profileDir
            }

            // Build searchable: name, "chrome", "browser", plus additional names if different
            var searchable = [name.lowercased(), "chrome", "browser"]
            if !gaiaName.isEmpty && gaiaName != name {
                searchable.append(gaiaName.lowercased())
            }
            if !userName.isEmpty {
                searchable.append(userName.lowercased())
            }

            items.append(PickerItem(
                id: "chrome:" + profileDir,
                title: name,
                subtitle: "Chrome Profile",
                icon: "bundle:com.google.Chrome",
                searchable: searchable,
                metadata: [
                    "action": "openChromeProfile",
                    "profileDir": profileDir
                ],
                priority: 100
            ))
        }

        return items
    }
}
