//
// SimpleBorderConfig.swift
// GridServer
//
// Configuration for window borders in active cell:
// - Active window border (focused window)
// - Inactive window borders (other windows in active cell)
//

import Foundation
import CoreGraphics

/// Shared runtime border configuration (mutable at runtime via RPC)
class BorderConfigManager {
    static let shared = BorderConfigManager()

    // MARK: - Configurable Properties

    var enabled: Bool = true

    // Active border configuration
    private var activeColor: CGColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)  // red
    private var activeWidth: CGFloat = 3.0
    private var activeCornerRadius: CGFloat = 8.0
    private var activeOpacity: CGFloat = 1.0

    // Inactive border configuration
    private var inactiveEnabled: Bool = true
    private var inactiveColor: CGColor = CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)  // #666666
    private var inactiveWidth: CGFloat = 3.0
    private var inactiveCornerRadius: CGFloat = 8.0
    private var inactiveOpacity: CGFloat = 1.0

    // Legacy properties (for backwards compatibility)
    var padding: CGFloat = 2.0  // Public for BorderWindow access
    private var styleString: String = "round"
    private var hidpi: Bool = true

    /// Callback invoked when config changes (for border refresh)
    var onConfigChanged: (() -> Void)?

    private init() {}

    // MARK: - Computed Properties

    /// Active window border style
    var activeStyle: BorderStyle {
        BorderStyle(
            color: activeColor,
            width: activeWidth,
            cornerRadius: activeCornerRadius,
            opacity: activeOpacity,
            styleType: parseStyleType(styleString)
        )
    }

    /// Inactive window border style (nil if disabled)
    var inactiveStyle: BorderStyle? {
        guard inactiveEnabled else { return nil }
        return BorderStyle(
            color: inactiveColor,
            width: inactiveWidth,
            cornerRadius: inactiveCornerRadius,
            opacity: inactiveOpacity,
            styleType: parseStyleType(styleString)
        )
    }

    // MARK: - Configuration Update

    /// Update configuration from RPC params
    /// Supports both new nested schema and legacy flat schema
    func update(from config: [String: Any]) {
        if let enabled = config["enabled"] as? Bool {
            self.enabled = enabled
        }

        // New nested schema
        if let activeConfig = config["active"] as? [String: Any] {
            updateActiveStyle(from: activeConfig)
        }

        if let inactiveConfig = config["inactive"] as? [String: Any] {
            updateInactiveStyle(from: inactiveConfig)
        }

        // Legacy flat schema (backwards compatibility)
        if let width = (config["width"] as? NSNumber)?.doubleValue {
            self.activeWidth = clamp(CGFloat(width), min: 1, max: 20)
        }

        if let cornerRadius = (config["corner_radius"] as? NSNumber)?.doubleValue {
            self.activeCornerRadius = clamp(CGFloat(cornerRadius), min: 0, max: 50)
        }

        if let padding = (config["padding"] as? NSNumber)?.doubleValue {
            self.padding = CGFloat(padding)
        }

        if let style = config["style"] as? String {
            self.styleString = style
        }

        if let hidpi = config["hidpi"] as? Bool {
            self.hidpi = hidpi
        }

        // Legacy color parsing
        if let colorStr = config["active_window_color"] as? String {
            if let color = parseHexColor(colorStr) {
                self.activeColor = color
            }
        }

        if let colorStr = config["inactive_color"] as? String {
            if let color = parseHexColor(colorStr) {
                self.inactiveColor = color
            }
        }

        // Notify listeners of config change
        onConfigChanged?()
    }

    // MARK: - Private Helpers

    /// Update active border style from config dictionary
    private func updateActiveStyle(from config: [String: Any]) {
        if let colorStr = config["color"] as? String, let color = parseHexColor(colorStr) {
            self.activeColor = color
        }

        if let width = (config["width"] as? NSNumber)?.doubleValue {
            self.activeWidth = clamp(CGFloat(width), min: 1, max: 20)
        }

        if let cornerRadius = (config["cornerRadius"] as? NSNumber)?.doubleValue {
            self.activeCornerRadius = clamp(CGFloat(cornerRadius), min: 0, max: 50)
        }

        if let opacity = (config["opacity"] as? NSNumber)?.doubleValue {
            self.activeOpacity = clamp(CGFloat(opacity), min: 0, max: 1)
        }
    }

    /// Update inactive border style from config dictionary
    private func updateInactiveStyle(from config: [String: Any]) {
        if let enabled = config["enabled"] as? Bool {
            self.inactiveEnabled = enabled
        }

        if let colorStr = config["color"] as? String, let color = parseHexColor(colorStr) {
            self.inactiveColor = color
        }

        if let width = (config["width"] as? NSNumber)?.doubleValue {
            self.inactiveWidth = clamp(CGFloat(width), min: 1, max: 20)
        }

        if let cornerRadius = (config["cornerRadius"] as? NSNumber)?.doubleValue {
            self.inactiveCornerRadius = clamp(CGFloat(cornerRadius), min: 0, max: 50)
        }

        if let opacity = (config["opacity"] as? NSNumber)?.doubleValue {
            self.inactiveOpacity = clamp(CGFloat(opacity), min: 0, max: 1)
        }
    }

    /// Clamp value to specified range
    private func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        return Swift.min(Swift.max(value, minValue), maxValue)
    }

    /// Parse style type string
    private func parseStyleType(_ style: String) -> BorderStyleType {
        switch style.lowercased() {
        case "round": return .round
        case "square": return .square
        case "uniform": return .uniform
        default: return .round
        }
    }

    /// Parse hex color string
    /// Accepts: "#RRGGBB", "0xRRGGBB", "RRGGBB" (6 chars, alpha=1.0)
    ///          "#AARRGGBB", "0xAARRGGBB", "AARRGGBB" (8 chars, with alpha)
    private func parseHexColor(_ hex: String) -> CGColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        } else if hexSanitized.hasPrefix("0x") || hexSanitized.hasPrefix("0X") {
            hexSanitized.removeFirst(2)
        }

        var alpha: CGFloat = 1.0
        var rgbHex: String

        switch hexSanitized.count {
        case 6:
            // RRGGBB format
            rgbHex = hexSanitized
        case 8:
            // AARRGGBB format
            let alphaStr = String(hexSanitized.prefix(2))
            rgbHex = String(hexSanitized.dropFirst(2))
            guard let alphaInt = UInt8(alphaStr, radix: 16) else {
                Task { await EventLog.shared.log("warn.config", ["msg": "failed to parse alpha in hex color", "hex": hex]) }
                return nil
            }
            alpha = CGFloat(alphaInt) / 255.0
        default:
            Task { await EventLog.shared.log("warn.config", ["msg": "invalid hex color format (expected 6 or 8 chars)", "hex": hex]) }
            return nil
        }

        guard let hexInt = UInt32(rgbHex, radix: 16) else {
            Task { await EventLog.shared.log("warn.config", ["msg": "failed to parse hex color", "hex": hex]) }
            return nil
        }

        let red = CGFloat((hexInt >> 16) & 0xFF) / 255.0
        let green = CGFloat((hexInt >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hexInt & 0xFF) / 255.0

        return CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Legacy border configuration helpers (deprecated)
@available(*, deprecated, message: "Use BorderConfigManager.shared.activeStyle instead")
struct SimpleBorderConfig {
    // MARK: - Active Window Border (legacy)

    /// Red border for focused window
    static var windowBorderColor: CGColor {
        BorderConfigManager.shared.activeStyle.color
    }

    /// Border width for focused window
    static var windowBorderWidth: CGFloat {
        BorderConfigManager.shared.activeStyle.width
    }
}
