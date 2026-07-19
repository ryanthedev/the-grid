import Foundation
import Yams

// MARK: - NotifyConfig

// Runtime configuration for GridNotify, loaded from notify.yaml.
struct NotifyConfig {
    // Path to the named pipe or file to watch for notifications.
    // Default: "$XDG_STATE_HOME/thegrid/notify.pipe"
    var pipePath: String

    // Source label written into GridNotification.source for pipe notifications.
    var pipeSourceLabel: String

    // Maximum stored non-pinned notifications; 0 = unlimited.
    var maxCount: Int

    // Raw hex color dict passed to NotificationPanelTheme.init(from:). Empty = use defaults.
    var themeColors: [String: String]

    // Managed scripts — launched as supervised child processes
    var scripts: [ScriptEntry]

    struct ScriptEntry {
        var name: String
        var path: String
        var arguments: [String]
        var enabled: Bool
        // Restart delay in seconds after crash. 0 = don't restart.
        var restartDelay: TimeInterval
    }

    init(
        pipePath: String = "\(XDG.stateHome)/thegrid/notify.pipe",
        pipeSourceLabel: String = "pipe",
        maxCount: Int = 0,
        themeColors: [String: String] = [:],
        scripts: [ScriptEntry] = []
    ) {
        self.pipePath = pipePath
        self.pipeSourceLabel = pipeSourceLabel
        self.maxCount = maxCount
        self.themeColors = themeColors
        self.scripts = scripts
    }
}

// MARK: - YAML Structs

private struct NotifyConfigYAML: Codable {
    var pipe: PipeYAML?
    var maxCount: Int?
    var theme: [String: String]?
    var scripts: [ScriptYAML]?

    private enum CodingKeys: String, CodingKey {
        case pipe
        case maxCount = "max_count"
        case theme
        case scripts
    }
}

private struct PipeYAML: Codable {
    var path: String?
    var sourceLabel: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case sourceLabel = "source_label"
    }
}

private struct ScriptYAML: Codable {
    var name: String
    var path: String
    var arguments: [String]?
    var enabled: Bool?
    var restartDelay: Double?

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case arguments
        case enabled
        case restartDelay = "restart_delay"
    }
}

// MARK: - Loader

// Loads notify.yaml from XDG config path. Returns defaults if file is missing.
func loadNotifyConfig() -> NotifyConfig {
    let configPath = "\(XDG.configHome)/thegrid/notify.yaml"
    let fm = FileManager.default

    guard fm.fileExists(atPath: configPath) else {
        jlog("notify.cfg.default", msg: "no config file, using defaults", data: ["path": configPath])
        return NotifyConfig()
    }

    do {
        let yamlString = try String(contentsOfFile: configPath, encoding: .utf8)
        return try loadNotifyConfigFromYAML(yamlString: yamlString)
    } catch {
        jlog("err.notify.cfg.load", msg: "failed to parse notify.yaml", data: [
            "path": configPath,
            "err": "\(error)"
        ])
        return NotifyConfig()
    }
}

// Parses a NotifyConfig from a raw YAML string.
// Internal so tests can exercise parsing without touching the filesystem.
// Returns defaults for any section that is absent or invalid.
func loadNotifyConfigFromYAML(yamlString: String) throws -> NotifyConfig {
    let decoder = YAMLDecoder()
    let yaml = try decoder.decode(NotifyConfigYAML.self, from: yamlString)

    var config = NotifyConfig()

    if let pipePath = yaml.pipe?.path {
        config.pipePath = expandTilde(pipePath)
    }
    if let sourceLabel = yaml.pipe?.sourceLabel {
        config.pipeSourceLabel = sourceLabel
    }
    if let maxCount = yaml.maxCount {
        config.maxCount = maxCount
    }
    if let theme = yaml.theme {
        config.themeColors = theme
    }

    if let scripts = yaml.scripts {
        config.scripts = scripts.map { s in
            NotifyConfig.ScriptEntry(
                name: s.name,
                path: expandTilde(s.path),
                arguments: (s.arguments ?? []).map { expandTilde($0) },
                enabled: s.enabled ?? true,
                restartDelay: s.restartDelay ?? 5.0
            )
        }
    }

    return config
}

// MARK: - Helpers

// Expands leading ~ to the user's home directory.
private func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + String(path.dropFirst(1))
    }
    return path
}
