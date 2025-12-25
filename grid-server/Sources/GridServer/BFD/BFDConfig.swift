import Foundation
import Yams

enum BFDError: Error {
    case noConfigFound(searchedPaths: [String])
    case parseError(path: String, underlying: Error)
}

/// Global defaults for hotkey behavior
struct BFDDefaults: Codable {
    var repeat_: Bool = true
    var rateLimit: Int = 50  // ms

    enum CodingKeys: String, CodingKey {
        case repeat_ = "repeat"
        case rateLimit = "rate_limit"
    }
}

/// Single hotkey definition (can be simple string or extended format)
struct BFDHotkeyDef: Codable {
    let run: String
    let repeat_: Bool?
    let rateLimit: Int?

    enum CodingKeys: String, CodingKey {
        case run
        case repeat_ = "repeat"
        case rateLimit = "rate_limit"
    }

    init(run: String, repeat_: Bool? = nil, rateLimit: Int? = nil) {
        self.run = run
        self.repeat_ = repeat_
        self.rateLimit = rateLimit
    }

    init(from decoder: Decoder) throws {
        // Try decoding as a simple string first
        if let container = try? decoder.singleValueContainer(),
           let simpleCommand = try? container.decode(String.self) {
            self.run = simpleCommand
            self.repeat_ = nil
            self.rateLimit = nil
            return
        }

        // Otherwise decode as object
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.run = try container.decode(String.self, forKey: .run)
        self.repeat_ = try container.decodeIfPresent(Bool.self, forKey: .repeat_)
        self.rateLimit = try container.decodeIfPresent(Int.self, forKey: .rateLimit)
    }
}

/// App-specific hotkey overrides
/// Value can be "~" for passthrough, a command string, or extended format
enum BFDAppHotkey: Codable {
    case passthrough
    case command(String)
    case extended(BFDHotkeyDef)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            if str == "~" {
                self = .passthrough
            } else {
                self = .command(str)
            }
        } else {
            let def = try BFDHotkeyDef(from: decoder)
            self = .extended(def)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .passthrough:
            try container.encode("~")
        case .command(let cmd):
            try container.encode(cmd)
        case .extended(let def):
            try def.encode(to: encoder)
        }
    }
}

/// Main BFD configuration
struct BFDConfig: Codable {
    var shell: String = "/bin/zsh"
    var vars: [String: String] = [:]
    var defaults: BFDDefaults = BFDDefaults()
    var blacklist: [String] = []
    var hotkeys: [String: BFDHotkeyDef] = [:]
    var apps: [String: [String: BFDAppHotkey]] = [:]

    enum CodingKeys: String, CodingKey {
        case shell, vars, defaults, blacklist, hotkeys, apps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? "/bin/zsh"
        vars = try container.decodeIfPresent([String: String].self, forKey: .vars) ?? [:]
        defaults = try container.decodeIfPresent(BFDDefaults.self, forKey: .defaults) ?? BFDDefaults()
        blacklist = try container.decodeIfPresent([String].self, forKey: .blacklist) ?? []
        hotkeys = try container.decodeIfPresent([String: BFDHotkeyDef].self, forKey: .hotkeys) ?? [:]
        apps = try container.decodeIfPresent([String: [String: BFDAppHotkey]].self, forKey: .apps) ?? [:]
    }

    private static func builtinDefaults() -> [String: Any] {
        return [
            "shell": "/bin/zsh",
            "defaults": [
                "repeat": false,
                "rate_limit": 50
            ],
            "vars": [:],
            "blacklist": [],
            "hotkeys": [:],
            "apps": [:]
        ]
    }

    /// Load config using XDG resolution with layered merging.
    /// This is the primary entry point for normal operation.
    static func load() async throws -> BFDConfig {
        let files = await XDG.findConfigFiles(app: "thegrid", filename: "bfd.yaml")

        JSONLogger.shared.log("cfg.resolve", data: [
            "xdg_config_home": XDG.configHome,
            "xdg_config_dirs": XDG.configDirs,
            "files_found": files
        ])

        var merged: [String: Any] = builtinDefaults()

        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            } catch {
                throw BFDError.parseError(path: file, underlying: error)
            }

            let dict: [String: Any]
            do {
                guard let parsed = try Yams.load(yaml: String(data: data, encoding: .utf8) ?? "") as? [String: Any] else {
                    continue
                }
                dict = parsed
            } catch {
                throw BFDError.parseError(path: file, underlying: error)
            }

            merged = deepMerge(merged, dict)
            JSONLogger.shared.log("cfg.merge", data: ["path": file])
        }

        let localPath = "\(XDG.configHome)/thegrid/bfd.local.yaml"
        if FileManager.default.fileExists(atPath: localPath) {
            let localData: Data
            do {
                localData = try Data(contentsOf: URL(fileURLWithPath: localPath))
            } catch {
                throw BFDError.parseError(path: localPath, underlying: error)
            }

            do {
                if let localDict = try Yams.load(yaml: String(data: localData, encoding: .utf8) ?? "") as? [String: Any] {
                    merged = deepMerge(merged, localDict)
                    JSONLogger.shared.log("cfg.merge", data: ["path": localPath, "layer": "local"])
                }
            } catch {
                throw BFDError.parseError(path: localPath, underlying: error)
            }
        }

        if files.isEmpty && !FileManager.default.fileExists(atPath: localPath) {
            var searched = XDG.configDirs.map { "\($0)/thegrid/bfd.yaml" }
            searched.append("\(XDG.configHome)/thegrid/bfd.yaml")
            throw BFDError.noConfigFound(searchedPaths: searched)
        }

        let yaml = try Yams.dump(object: merged)
        return try YAMLDecoder().decode(BFDConfig.self, from: yaml)
    }

    /// Load config from explicit path (no XDG resolution, no layering).
    /// Use this when user provides --config flag.
    static func load(from path: String) throws -> BFDConfig {
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let data = try Data(contentsOf: url)
        let decoder = YAMLDecoder()
        return try decoder.decode(BFDConfig.self, from: data)
    }

    /// Default config file path
    static var defaultPath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.config/thegrid/bfd.yaml"
    }

    /// Expand variables in a command string
    func expandVars(_ command: String) -> String {
        var result = command
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "$\(key)", with: value)
        }
        return result
    }

    /// Get effective repeat setting for a hotkey
    func effectiveRepeat(for def: BFDHotkeyDef) -> Bool {
        return def.repeat_ ?? defaults.repeat_
    }

    /// Get effective rate limit for a hotkey
    func effectiveRateLimit(for def: BFDHotkeyDef) -> Int {
        return def.rateLimit ?? defaults.rateLimit
    }
}
