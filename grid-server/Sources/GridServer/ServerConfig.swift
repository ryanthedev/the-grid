import Foundation
import Yams

/// Server configuration for window management behavior
struct ServerConfig: Codable {
    /// Apps whose windows should not be tracked (by bundle ID or app name)
    var windowBlacklist: [String] = []

    /// Path to CLI binary for invoking border sync on external focus changes
    /// Defaults to "thegrid" (assumes in PATH)
    var cliPath: String = "thegrid"

    enum CodingKeys: String, CodingKey {
        case windowBlacklist = "window_blacklist"
        case cliPath = "cli_path"
    }

    init() {}

    private static func builtinDefaults() -> [String: Any] {
        return [
            "window_blacklist": [],
            "cli_path": "thegrid"
        ]
    }

    /// Load config using XDG resolution with layered merging
    static func load() async throws -> ServerConfig {
        let files = await XDG.findConfigFiles(app: "thegrid", filename: "config.yaml")

        JSONLogger.shared.log("srv.cfg.resolve", data: [
            "xdg_config_home": XDG.configHome,
            "files_found": files
        ])

        var merged: [String: Any] = builtinDefaults()

        for file in files {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                guard let yaml = String(data: data, encoding: .utf8),
                      let dict = try Yams.load(yaml: yaml) as? [String: Any] else {
                    JSONLogger.shared.log("srv.cfg.skip", msg: "invalid yaml", data: ["file": file])
                    continue
                }
                merged = deepMerge(merged, dict)
            } catch {
                JSONLogger.shared.log("srv.cfg.skip", msg: "failed to read", data: ["file": file, "error": "\(error)"])
                continue
            }
        }

        // Load local overlay
        let localPath = "\(XDG.configHome)/thegrid/config.local.yaml"
        if FileManager.default.fileExists(atPath: localPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
                if let yaml = String(data: data, encoding: .utf8),
                   let dict = try Yams.load(yaml: yaml) as? [String: Any] {
                    merged = deepMerge(merged, dict)
                    JSONLogger.shared.log("srv.cfg.merge", data: ["path": localPath, "layer": "local"])
                }
            } catch {
                JSONLogger.shared.log("srv.cfg.skip", msg: "failed to read local", data: ["error": "\(error)"])
            }
        }

        let yamlStr = try Yams.dump(object: merged)
        return try YAMLDecoder().decode(ServerConfig.self, from: yamlStr)
    }
}
