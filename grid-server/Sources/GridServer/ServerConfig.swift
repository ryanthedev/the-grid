import Foundation
import Yams
import CoreGraphics

/// Picker style configuration (loaded from config file)
struct PickerConfig: Codable {
    var width: CGFloat?
    var maxVisibleItems: Int?
    var itemHeight: CGFloat?
    var inputHeight: CGFloat?
    var padding: CGFloat?
    var fontName: String?
    var fontSize: CGFloat?
    var inputFontSize: CGFloat?
    var backgroundColor: String?
    var inputBackgroundColor: String?
    var textColor: String?
    var secondaryTextColor: String?
    var selectedBackgroundColor: String?
    var matchHighlightColor: String?
    var cursorColor: String?
    var borderColor: String?
    var cornerRadius: CGFloat?
    var borderWidth: CGFloat?

    enum CodingKeys: String, CodingKey {
        case width
        case maxVisibleItems = "max_visible_items"
        case itemHeight = "item_height"
        case inputHeight = "input_height"
        case padding
        case fontName = "font_name"
        case fontSize = "font_size"
        case inputFontSize = "input_font_size"
        case backgroundColor = "background_color"
        case inputBackgroundColor = "input_background_color"
        case textColor = "text_color"
        case secondaryTextColor = "secondary_text_color"
        case selectedBackgroundColor = "selected_background_color"
        case matchHighlightColor = "match_highlight_color"
        case cursorColor = "cursor_color"
        case borderColor = "border_color"
        case cornerRadius = "corner_radius"
        case borderWidth = "border_width"
    }

    /// Convert to PickerStyle, merging with defaults
    func toPickerStyle() -> PickerStyle {
        var style = PickerStyle.default
        if let width = width { style.width = width }
        if let maxVisibleItems = maxVisibleItems { style.maxVisibleItems = maxVisibleItems }
        if let itemHeight = itemHeight { style.itemHeight = itemHeight }
        if let inputHeight = inputHeight { style.inputHeight = inputHeight }
        if let padding = padding { style.padding = padding }
        if let fontName = fontName { style.fontName = fontName }
        if let fontSize = fontSize { style.fontSize = fontSize }
        if let inputFontSize = inputFontSize { style.inputFontSize = inputFontSize }
        if let backgroundColor = backgroundColor { style.backgroundColor = backgroundColor }
        if let inputBackgroundColor = inputBackgroundColor { style.inputBackgroundColor = inputBackgroundColor }
        if let textColor = textColor { style.textColor = textColor }
        if let secondaryTextColor = secondaryTextColor { style.secondaryTextColor = secondaryTextColor }
        if let selectedBackgroundColor = selectedBackgroundColor { style.selectedBackgroundColor = selectedBackgroundColor }
        if let matchHighlightColor = matchHighlightColor { style.matchHighlightColor = matchHighlightColor }
        if let cursorColor = cursorColor { style.cursorColor = cursorColor }
        if let borderColor = borderColor { style.borderColor = borderColor }
        if let cornerRadius = cornerRadius { style.cornerRadius = cornerRadius }
        if let borderWidth = borderWidth { style.borderWidth = borderWidth }
        return style
    }
}

/// Server configuration for window management behavior
struct ServerConfig: Codable {
    /// Apps whose windows should not be tracked (by bundle ID or app name)
    var windowBlacklist: [String] = []

    /// Path to CLI binary for invoking border sync on external focus changes
    /// Defaults to "thegrid" (assumes in PATH)
    var cliPath: String = "thegrid"

    /// Picker UI configuration
    var picker: PickerConfig?

    enum CodingKeys: String, CodingKey {
        case windowBlacklist = "window_blacklist"
        case cliPath = "cli_path"
        case picker
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
