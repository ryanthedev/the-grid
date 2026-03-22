import SwiftUI
import AppKit

// Color palette for the notification panel. All colors are SwiftUI Color
// for direct use in views. A configurable struct with sensible dark-theme
// defaults; Phase 5 replaces colors from YAML config at init time.
struct NotificationPanelTheme {
    // #121212 - deep dark background, matches PickerColors.background
    let background: Color
    // #1E1E1E - slightly lifted card/item surface
    let surface: Color
    // #2A2A2A - selected item highlight
    let surfaceSelected: Color
    // #BFBFBF - main text (title), matches PickerColors.text
    let textPrimary: Color
    // #808080 - body/metadata text
    let textSecondary: Color
    // #5A5A5A - timestamps, source labels
    let textTertiary: Color
    // #FF9500 - warm attention accent for priority indicators, action hints
    let accent: Color
    // #CC7700 - shaded accent for unfocused elements
    let accentDim: Color
    // #FF3B30 - urgent priority indicator
    let urgent: Color
    // #FFD60A - pin indicator
    let pinned: Color
    // #333333 - subtle dividers
    let border: Color
    // #232323 - filter input background, matches PickerColors.inputBackground
    let filterBackground: Color

    // NSColor version of background for NSWindow.backgroundColor
    let windowBackgroundNSColor: NSColor

    init(
        background: Color,
        surface: Color,
        surfaceSelected: Color,
        textPrimary: Color,
        textSecondary: Color,
        textTertiary: Color,
        accent: Color,
        accentDim: Color,
        urgent: Color,
        pinned: Color,
        border: Color,
        filterBackground: Color,
        windowBackgroundNSColor: NSColor
    ) {
        self.background = background
        self.surface = surface
        self.surfaceSelected = surfaceSelected
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
        self.accentDim = accentDim
        self.urgent = urgent
        self.pinned = pinned
        self.border = border
        self.filterBackground = filterBackground
        self.windowBackgroundNSColor = windowBackgroundNSColor
    }

    static let `default` = NotificationPanelTheme(
        background: Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0),
        surface: Color(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0),
        surfaceSelected: Color(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0),
        textPrimary: Color(red: 0xBF / 255.0, green: 0xBF / 255.0, blue: 0xBF / 255.0),
        textSecondary: Color(red: 0x80 / 255.0, green: 0x80 / 255.0, blue: 0x80 / 255.0),
        textTertiary: Color(red: 0x5A / 255.0, green: 0x5A / 255.0, blue: 0x5A / 255.0),
        accent: Color(red: 0xFF / 255.0, green: 0x95 / 255.0, blue: 0x00 / 255.0),
        accentDim: Color(red: 0xCC / 255.0, green: 0x77 / 255.0, blue: 0x00 / 255.0),
        urgent: Color(red: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0),
        pinned: Color(red: 0xFF / 255.0, green: 0xD6 / 255.0, blue: 0x0A / 255.0),
        border: Color(red: 0x33 / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0),
        filterBackground: Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0),
        windowBackgroundNSColor: NSColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1.0)
    )

    // Convenience init from hex string dictionary (used by Phase 5 YAML config).
    // Missing keys fall back to default values.
    init(from dictionary: [String: String]) {
        let d = NotificationPanelTheme.default
        self.background = Self.parseHex(dictionary["background"]) ?? d.background
        self.surface = Self.parseHex(dictionary["surface"]) ?? d.surface
        self.surfaceSelected = Self.parseHex(dictionary["surfaceSelected"]) ?? d.surfaceSelected
        self.textPrimary = Self.parseHex(dictionary["textPrimary"]) ?? d.textPrimary
        self.textSecondary = Self.parseHex(dictionary["textSecondary"]) ?? d.textSecondary
        self.textTertiary = Self.parseHex(dictionary["textTertiary"]) ?? d.textTertiary
        self.accent = Self.parseHex(dictionary["accent"]) ?? d.accent
        self.accentDim = Self.parseHex(dictionary["accentDim"]) ?? d.accentDim
        self.urgent = Self.parseHex(dictionary["urgent"]) ?? d.urgent
        self.pinned = Self.parseHex(dictionary["pinned"]) ?? d.pinned
        self.border = Self.parseHex(dictionary["border"]) ?? d.border
        self.filterBackground = Self.parseHex(dictionary["filterBackground"]) ?? d.filterBackground

        if let bgHex = dictionary["background"], let nsColor = Self.parseHexToNSColor(bgHex) {
            self.windowBackgroundNSColor = nsColor
        } else {
            self.windowBackgroundNSColor = d.windowBackgroundNSColor
        }
    }

    // Parse a hex color string like "#FF9500" or "FF9500" into a SwiftUI Color.
    // Returns nil on invalid input.
    private static func parseHex(_ hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6 else { return nil }
        guard let value = UInt64(trimmed, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    // Parse a hex color string into NSColor for window background.
    private static func parseHexToNSColor(_ hex: String) -> NSColor? {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6 else { return nil }
        guard let value = UInt64(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
