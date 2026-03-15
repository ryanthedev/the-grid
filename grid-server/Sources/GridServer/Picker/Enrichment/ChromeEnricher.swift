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

    // Resolved default profile info (from "Default" directory in Local State)
    private var defaultProfileName: String?
    private var defaultProfileEmail: String?

    // Supported bundle IDs (only Chrome; other browsers use different Local State paths)
    private let supportedBundleIDs: Set<String> = [
        "com.google.Chrome"
    ]

    // Pattern: "Page Title - Google Chrome - Profile Name"
    // Captures profile name after browser identifier
    private static let profilePattern = try! NSRegularExpression(
        pattern: #"- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$"#
    )

    // Pattern: "Page Title - Google Chrome" (no profile suffix = default profile)
    private static let browserSuffixPattern = try! NSRegularExpression(
        pattern: #"^(.+?) - (?:Google Chrome|Brave|Chromium|Microsoft Edge)$"#
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
        // Load Local State lazily (once per enricher lifetime)
        if !loaded {
            loadLocalState()
            loaded = true
        }

        let nsTitle = windowTitle as NSString
        let range = NSRange(location: 0, length: nsTitle.length)

        // 1. Check for explicit profile suffix: "Page - Google Chrome - ProfileName"
        if let match = Self.profilePattern.firstMatch(in: windowTitle, range: range) {
            let profileNameRange = match.range(at: 1)
            let profileName = nsTitle.substring(with: profileNameRange)

            // Extract clean page title (everything before the match)
            let pageTitle = nsTitle.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespaces)

            // Lookup email from Local State cache
            var email = ""
            if let dir = nameToDir[profileName], let info = infoCache[dir] {
                email = info.userName
            }

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

        // 2. Check for browser suffix without profile: "Page - Google Chrome"
        //    This is the default profile (Chrome omits profile name for it)
        if let match = Self.browserSuffixPattern.firstMatch(in: windowTitle, range: range) {
            let pageTitleRange = match.range(at: 1)
            let pageTitle = nsTitle.substring(with: pageTitleRange)

            // Look up the actual default profile name from Local State
            let subtitle: String
            let profileLabel: String
            if let name = defaultProfileName, !name.isEmpty {
                if let email = defaultProfileEmail, !email.isEmpty {
                    subtitle = "\(name) (\(email))"
                } else {
                    subtitle = name
                }
                profileLabel = name
            } else {
                subtitle = ""
                profileLabel = "Default"
            }

            return EnrichmentResult(
                title: pageTitle,
                subtitle: subtitle,
                stableIDSuffix: "chrome:\(profileLabel)",
                kind: .chrome
            )
        }

        // 3. No browser suffix at all — not a recognizable Chrome title
        //    (CGWindowList fallback title, popups, etc.)
        return nil
    }

    // MARK: - Local State Loading

    private func loadLocalState() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localStatePath = "\(home)/Library/Application Support/Google/Chrome/Local State"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)) else {
            return
        }

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

            // Capture the "Default" directory's profile info
            if dir == "Default" {
                defaultProfileName = name.isEmpty ? gaiaName : name
                defaultProfileEmail = userName
            }

            // Build reverse lookup: displayName -> dir
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
