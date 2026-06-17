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

    // Configuration for the tmux status dashboard driver.
    // Parsed from the `tmux:` block in notify.yaml.
    struct Tmux {
        // Whether the tmux dashboard is enabled. Default: false (off-by-default;
        // each tick spends a Claude run).
        var enabled: Bool
        // How often (seconds) the driver runs a status refresh. Default: 60.
        // Values < 1 are clamped to 1 to prevent restart-storm.
        var interval: TimeInterval
        // Absolute path to the repository root used as the cwd for headless claude.
        var repoDir: String
        // Claude model override for the headless run. nil = use claude default.
        var model: String?

        init(
            enabled: Bool = false,
            interval: TimeInterval = 60,
            repoDir: String = "",
            model: String? = nil
        ) {
            self.enabled = enabled
            self.interval = interval
            self.repoDir = repoDir
            self.model = model
        }
    }

    // tmux dashboard config. Defaults to disabled until the user enables it.
    var tmux: Tmux

    init(
        pipePath: String = "\(XDG.stateHome)/thegrid/notify.pipe",
        pipeSourceLabel: String = "pipe",
        maxCount: Int = 0,
        themeColors: [String: String] = [:],
        scripts: [ScriptEntry] = [],
        tmux: Tmux = Tmux()
    ) {
        self.pipePath = pipePath
        self.pipeSourceLabel = pipeSourceLabel
        self.maxCount = maxCount
        self.themeColors = themeColors
        self.scripts = scripts
        self.tmux = tmux
    }
}

// MARK: - YAML Structs

private struct NotifyConfigYAML: Codable {
    var pipe: PipeYAML?
    var maxCount: Int?
    var theme: [String: String]?
    var scripts: [ScriptYAML]?
    var tmux: TmuxYAML?

    private enum CodingKeys: String, CodingKey {
        case pipe
        case maxCount = "max_count"
        case theme
        case scripts
        case tmux
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

// YAML structure for the `tmux:` block in notify.yaml.
//
// Example:
//   tmux:
//     enabled: true
//     interval: 60
//     repo_dir: ~/repos/theGrid
//     model: claude-sonnet-4-5
private struct TmuxYAML: Codable {
    var enabled: Bool?
    var interval: Double?
    var repoDir: String?
    var model: String?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case interval
        case repoDir = "repo_dir"
        case model
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

    if let tmuxYAML = yaml.tmux {
        // Clamp interval to at least 1 second to prevent restart-storm on
        // invalid (zero or negative) config values.
        let rawInterval = tmuxYAML.interval ?? 60
        let clampedInterval = max(1, rawInterval)
        config.tmux = NotifyConfig.Tmux(
            enabled: tmuxYAML.enabled ?? false,
            interval: clampedInterval,
            repoDir: expandTilde(tmuxYAML.repoDir ?? ""),
            model: tmuxYAML.model
        )
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
