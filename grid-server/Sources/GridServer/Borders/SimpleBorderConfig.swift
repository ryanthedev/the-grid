//
// SimpleBorderConfig.swift
// GridServer
//
// Simple configuration for the 2-element border system:
// - Cell highlight (white background with blue border)
// - Active window border (red border)
//

import Foundation
import CoreGraphics
import Logging

/// Shared runtime border configuration (mutable at runtime via RPC)
class BorderConfigManager {
    static let shared = BorderConfigManager()

    private let logger = Logger(label: "com.grid.BorderConfigManager")

    // MARK: - Configurable Properties

    var enabled: Bool = true
    var borderWidth: CGFloat = 3.0
    var cornerRadius: CGFloat = 8.0
    var padding: CGFloat = 2.0
    var style: String = "round"
    var hidpi: Bool = true

    // Colors (stored as CGColor for direct use)
    var activeWindowColor: CGColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)  // red
    var activeCellColor: CGColor = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.6)    // white 60%
    var inactiveColor: CGColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)      // gray

    private init() {}

    /// Update configuration from RPC params
    func update(from config: [String: Any]) {
        logger.info("Updating border config", metadata: ["keys": "\(config.keys.sorted())"])

        if let enabled = config["enabled"] as? Bool {
            self.enabled = enabled
            logger.debug("Set enabled", metadata: ["value": "\(enabled)"])
        }

        if let width = (config["width"] as? NSNumber)?.doubleValue {
            self.borderWidth = CGFloat(width)
            logger.debug("Set borderWidth", metadata: ["value": "\(width)"])
        }

        if let cornerRadius = (config["corner_radius"] as? NSNumber)?.doubleValue {
            self.cornerRadius = CGFloat(cornerRadius)
            logger.debug("Set cornerRadius", metadata: ["value": "\(cornerRadius)"])
        }

        if let padding = (config["padding"] as? NSNumber)?.doubleValue {
            self.padding = CGFloat(padding)
            logger.debug("Set padding", metadata: ["value": "\(padding)"])
        }

        if let style = config["style"] as? String {
            self.style = style
            logger.debug("Set style", metadata: ["value": "\(style)"])
        }

        if let hidpi = config["hidpi"] as? Bool {
            self.hidpi = hidpi
            logger.debug("Set hidpi", metadata: ["value": "\(hidpi)"])
        }

        // Parse colors (expect hex strings like "#FF0000" or "0xFF0000")
        if let colorStr = config["active_window_color"] as? String {
            if let color = parseHexColor(colorStr) {
                self.activeWindowColor = color
                logger.debug("Set activeWindowColor", metadata: ["value": "\(colorStr)"])
            }
        }

        if let colorStr = config["active_cell_color"] as? String {
            if let color = parseHexColor(colorStr) {
                self.activeCellColor = color
                logger.debug("Set activeCellColor", metadata: ["value": "\(colorStr)"])
            }
        }

        if let colorStr = config["inactive_color"] as? String {
            if let color = parseHexColor(colorStr) {
                self.inactiveColor = color
                logger.debug("Set inactiveColor", metadata: ["value": "\(colorStr)"])
            }
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
                logger.warning("Failed to parse alpha in hex color", metadata: ["hex": "\(hex)"])
                return nil
            }
            alpha = CGFloat(alphaInt) / 255.0
        default:
            logger.warning("Invalid hex color format (expected 6 or 8 chars)", metadata: ["hex": "\(hex)"])
            return nil
        }

        guard let hexInt = UInt32(rgbHex, radix: 16) else {
            logger.warning("Failed to parse hex color", metadata: ["hex": "\(hex)"])
            return nil
        }

        let red = CGFloat((hexInt >> 16) & 0xFF) / 255.0
        let green = CGFloat((hexInt >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hexInt & 0xFF) / 255.0

        return CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Simple border configuration with static defaults (backwards compatible)
struct SimpleBorderConfig {
    // MARK: - Cell Highlight (background overlay behind windows)

    /// Solid white background for cell highlight
    static var highlightFillColor: CGColor {
        BorderConfigManager.shared.activeCellColor
    }

    /// Blue stroke for cell highlight border
    static let highlightStrokeColor: CGColor = CGColor(
        red: 0.0,
        green: 0x88 / 255.0,  // 0x0088ff
        blue: 1.0,
        alpha: 1.0
    )

    /// Stroke width for cell highlight
    static let highlightStrokeWidth: CGFloat = 2.0

    // MARK: - Active Window Border

    /// Red border for focused window
    static var windowBorderColor: CGColor {
        BorderConfigManager.shared.activeWindowColor
    }

    /// Border width for focused window
    static var windowBorderWidth: CGFloat {
        BorderConfigManager.shared.borderWidth
    }
}
