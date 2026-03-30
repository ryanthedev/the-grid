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

    init(
        pipePath: String = "\(XDG.stateHome)/thegrid/notify.pipe",
        pipeSourceLabel: String = "pipe",
        maxCount: Int = 0,
        themeColors: [String: String] = [:]
    ) {
        self.pipePath = pipePath
        self.pipeSourceLabel = pipeSourceLabel
        self.maxCount = maxCount
        self.themeColors = themeColors
    }
}

// MARK: - YAML Structs

private struct NotifyConfigYAML: Codable {
    var pipe: PipeYAML?
    var maxCount: Int?
    var theme: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case pipe
        case maxCount = "max_count"
        case theme
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

        return config
    } catch {
        jlog("err.notify.cfg.load", msg: "failed to parse notify.yaml", data: [
            "path": configPath,
            "err": "\(error)"
        ])
        return NotifyConfig()
    }
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
