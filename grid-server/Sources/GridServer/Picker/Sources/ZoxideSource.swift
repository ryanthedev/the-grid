//
// ZoxideSource.swift
// GridServer
//
// PickerSource that queries zoxide for frecency-ranked directories.
// Port of Go DiscoverZoxide().
//

import Foundation

/// Discovers directories from zoxide's frecency database
struct ZoxideSource: PickerSource {
    let id = "zoxide"

    /// Optional config override for zoxide binary path
    let configuredPath: String?

    func discover() async throws -> [PickerItem] {
        // Find zoxide binary
        guard let zoxidePath = findZoxide() else {
            // zoxide not installed — not an error, just return empty
            return []
        }

        // Run: zoxide query -l
        guard let output = await runProcess(zoxidePath, args: ["query", "-l"]) else {
            return []
        }

        let home = NSHomeDirectory()
        var items: [PickerItem] = []

        for line in output.split(separator: "\n") {
            let dir = line.trimmingCharacters(in: .whitespaces)
            guard !dir.isEmpty else { continue }

            // Display path with ~ substitution
            let displayPath: String
            if dir.hasPrefix(home) {
                displayPath = "~" + dir.dropFirst(home.count)
            } else {
                displayPath = dir
            }

            // Title is basename
            let title = (dir as NSString).lastPathComponent

            items.append(PickerItem(
                id: "zoxide:" + displayPath,
                title: title,
                subtitle: displayPath,
                icon: "folder",
                searchable: [title.lowercased(), displayPath.lowercased()],
                metadata: [
                    "action": "openDir",
                    "dirPath": dir
                ],
                priority: 50
            ))
        }

        return items
    }

    // MARK: - Private

    /// Find zoxide binary by config override or known absolute paths.
    /// Server runs via launchd with minimal PATH, so check absolute paths.
    private func findZoxide() -> String? {
        // 1. Config override (use unconditionally if set)
        if let configured = configuredPath, !configured.isEmpty {
            if FileManager.default.isExecutableFile(atPath: configured) {
                return configured
            }
            jlog("pick.zoxide.warn", data: ["configured": configured, "msg": "not found"])
            return nil
        }

        // 2. Check known install paths
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.cargo/bin/zoxide",
            "/opt/homebrew/bin/zoxide",
            "/usr/local/bin/zoxide"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }
}
