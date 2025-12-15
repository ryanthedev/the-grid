//
// BorderConfig.swift
// GridServer
//
// Configuration for cell-aware window borders
//

import Foundation
import CoreGraphics
import Logging

/// Border visual style
enum BorderStyleType: String, Codable {
    case round = "round"
    case square = "square"
    case uniform = "uniform"
}

/// Focus tier for color resolution
enum FocusTier {
    case activeWindow   // The focused window
    case activeCell     // Other windows in focused cell
    case inactive       // Windows in other cells
}

/// Per-cell border style overrides
struct CellBorderStyle {
    var activeCellColor: CGColor?
    var inactiveColor: CGColor?
    var style: BorderStyleType?
}

/// Border configuration
class BorderConfig {
    private let logger = Logger(label: "com.grid.BorderConfig")

    // General settings
    var enabled: Bool = true
    var width: CGFloat = 5.0
    var style: BorderStyleType = .round
    var cornerRadius: CGFloat = 8.0
    var padding: CGFloat = 2.0
    var hidpiEnabled: Bool = true

    // Three-tier focus colors (defaults)
    var activeWindowColor: CGColor = CGColor(red: 0.88, green: 0.42, blue: 0.46, alpha: 1.0) // #e06c75
    var activeCellColor: CGColor = CGColor(red: 0.38, green: 0.69, blue: 0.94, alpha: 1.0)   // #61afef
    var inactiveColor: CGColor = CGColor(red: 0.36, green: 0.39, blue: 0.44, alpha: 1.0)    // #5c6370

    // Palette for auto-assignment
    var palette: [CGColor] = []

    // Per-cell overrides
    var cellOverrides: [String: CellBorderStyle] = [:]

    // App filtering
    var whitelist: Set<String> = []
    var blacklist: Set<String> = []

    // Palette assignment tracking
    private var paletteAssignments: [String: Int] = [:]
    private var nextPaletteIndex: Int = 0

    // MARK: - Color Resolution

    /// Get the effective color for a window based on its focus tier and cell
    func resolveColor(tier: FocusTier, cellID: String?) -> CGColor {
        switch tier {
        case .activeWindow:
            return activeWindowColor

        case .activeCell:
            guard let cellID = cellID else { return activeCellColor }

            // 1. Per-cell override
            if let override = cellOverrides[cellID]?.activeCellColor {
                return override
            }
            // 2. Palette
            if !palette.isEmpty {
                return palette[getPaletteIndex(for: cellID)]
            }
            // 3. Global default
            return activeCellColor

        case .inactive:
            guard let cellID = cellID else { return inactiveColor }

            // 1. Per-cell override
            if let override = cellOverrides[cellID]?.inactiveColor {
                return override
            }
            // 2. Dimmed palette color
            if !palette.isEmpty {
                let baseColor = palette[getPaletteIndex(for: cellID)]
                return dimColor(baseColor, by: 0.5)
            }
            // 3. Global default
            return inactiveColor
        }
    }

    /// Check if borders should be shown for an app
    func shouldShowBorder(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return true }

        // Blacklist takes priority
        if blacklist.contains(bundleID) {
            return false
        }

        // If whitelist is set, only show for whitelisted apps
        if !whitelist.isEmpty {
            return whitelist.contains(bundleID)
        }

        return true
    }

    // MARK: - Private Helpers

    private func getPaletteIndex(for cellID: String) -> Int {
        if let existing = paletteAssignments[cellID] {
            return existing
        }
        let index = nextPaletteIndex % palette.count
        paletteAssignments[cellID] = index
        nextPaletteIndex += 1
        return index
    }

    private func dimColor(_ color: CGColor, by factor: CGFloat) -> CGColor {
        guard let components = color.components, components.count >= 3 else {
            return color
        }

        let r = components[0] * factor
        let g = components[1] * factor
        let b = components[2] * factor
        let a = components.count >= 4 ? components[3] : 1.0

        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Parsing

    /// Parse color from hex string (0xAARRGGBB or 0xRRGGBB)
    static func parseColor(_ hex: String) -> CGColor? {
        var hexString = hex
        if hexString.hasPrefix("0x") {
            hexString = String(hexString.dropFirst(2))
        }

        guard let value = UInt32(hexString, radix: 16) else {
            return nil
        }

        let a, r, g, b: CGFloat
        if hexString.count == 8 {
            // 0xAARRGGBB
            a = CGFloat((value >> 24) & 0xFF) / 255.0
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
        } else {
            // 0xRRGGBB (assume full opacity)
            a = 1.0
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
        }

        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Load configuration from dictionary (parsed from YAML/JSON)
    static func load(from dict: [String: Any]) -> BorderConfig {
        let config = BorderConfig()

        if let enabled = dict["enabled"] as? Bool {
            config.enabled = enabled
        }
        if let width = dict["width"] as? Double {
            config.width = CGFloat(width)
        }
        if let styleStr = dict["style"] as? String, let style = BorderStyleType(rawValue: styleStr) {
            config.style = style
        }
        if let radius = dict["corner_radius"] as? Double {
            config.cornerRadius = CGFloat(radius)
        }
        if let padding = dict["padding"] as? Double {
            config.padding = CGFloat(padding)
        }
        if let hidpi = dict["hidpi"] as? Bool {
            config.hidpiEnabled = hidpi
        }

        // Colors
        if let colorHex = dict["active_window_color"] as? String, let color = parseColor(colorHex) {
            config.activeWindowColor = color
        }
        if let colorHex = dict["active_cell_color"] as? String, let color = parseColor(colorHex) {
            config.activeCellColor = color
        }
        if let colorHex = dict["inactive_color"] as? String, let color = parseColor(colorHex) {
            config.inactiveColor = color
        }

        // Palette
        if let paletteArray = dict["palette"] as? [String] {
            config.palette = paletteArray.compactMap { parseColor($0) }
        }

        // Blacklist/whitelist
        if let blacklistArray = dict["blacklist"] as? [String] {
            config.blacklist = Set(blacklistArray)
        }
        if let whitelistArray = dict["whitelist"] as? [String] {
            config.whitelist = Set(whitelistArray)
        }

        return config
    }
}
