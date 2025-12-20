import Foundation
import Yams

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

    /// Load config from file path
    static func load(from path: String) throws -> BFDConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
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
