//
// ChromeEnricher.swift
// GridServer
//
// Detects Chrome profile from window title regex.
// Reads Chrome Local State JSON for profile metadata (email, directory).
// No subprocess calls — file I/O only.
//

import Foundation

class ChromeEnricher {
    // profileDir -> ProfileInfo (from Local State JSON)
    private var infoCache: [String: ProfileInfo] = [:]

    // displayName -> profileDir (reverse lookup for title matching)
    private var nameToDir: [String: String] = [:]

    // Loaded flag — load lazily on first enrich call
    private var loaded = false

    // Supported bundle IDs (only Chrome; other browsers use different Local State paths)
    private let supportedBundleIDs: Set<String> = [
        "com.google.Chrome"
    ]

    // Pattern: "Page Title - Google Chrome - Profile Name"
    // Captures profile name after browser identifier
    private static let profilePattern = try! NSRegularExpression(
        pattern: #"- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$"#
    )

    struct ProfileInfo {
        let name: String
        let gaiaName: String
        let userName: String
    }

    // MARK: - Enrichment

    func supports(bundleID: String) -> Bool {
        return supportedBundleIDs.contains(bundleID)
    }

    func enrich(windowTitle: String) -> EnrichmentResult? {
        // 1. Regex match for profile suffix in window title
        let nsTitle = windowTitle as NSString
        let range = NSRange(location: 0, length: nsTitle.length)
        let match = Self.profilePattern.firstMatch(in: windowTitle, range: range)

        if match == nil {
            // No profile suffix = Default profile (or non-profile window)
            return EnrichmentResult(
                title: windowTitle,
                subtitle: "Default",
                stableIDSuffix: "chrome:Default",
                kind: .chrome
            )
        }

        // Extract profile name from capture group 1
        let profileNameRange = match!.range(at: 1)
        let profileName = nsTitle.substring(with: profileNameRange)

        // Extract clean page title (everything before the regex match, trimmed)
        let pageTitle = nsTitle.substring(to: match!.range.location)
            .trimmingCharacters(in: .whitespaces)

        // 2. Load Local State lazily (once per enricher lifetime)
        if !loaded {
            loadLocalState()
            loaded = true
        }

        // 3. Lookup profile dir and email from cache
        var email = ""
        if let dir = nameToDir[profileName] {
            if let info = infoCache[dir] {
                email = info.userName
            }
        }

        // 4. Build subtitle: "ProfileName (email)" or just "ProfileName"
        let subtitle: String
        if !email.isEmpty {
            subtitle = "\(profileName) (\(email))"
        } else {
            subtitle = profileName
        }

        return EnrichmentResult(
            title: pageTitle.isEmpty ? windowTitle : pageTitle,
            subtitle: subtitle,
            stableIDSuffix: "chrome:\(profileName)",
            kind: .chrome
        )
    }

    // MARK: - Local State Loading

    private func loadLocalState() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localStatePath = "\(home)/Library/Application Support/Google/Chrome/Local State"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)) else {
            // Chrome not installed — silent, no enrichment
            return
        }

        // Parse using JSONSerialization for flexibility with Chrome's complex JSON structure
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoMap = profile["info_cache"] as? [String: [String: Any]]
        else { return }

        for (dir, info) in infoMap {
            let name = info["name"] as? String ?? ""
            let gaiaName = info["gaia_name"] as? String ?? ""
            let userName = info["user_name"] as? String ?? ""
            let isDefault = info["is_using_default_name"] as? Bool ?? false

            infoCache[dir] = ProfileInfo(name: name, gaiaName: gaiaName, userName: userName)

            // Build reverse lookup: displayName -> dir
            // Prefer name unless isDefault, then fall back to gaiaName
            var displayName = name
            if displayName.isEmpty || isDefault {
                if !gaiaName.isEmpty {
                    displayName = gaiaName
                }
            }
            if !displayName.isEmpty {
                nameToDir[displayName] = dir
            }
        }
    }
}
