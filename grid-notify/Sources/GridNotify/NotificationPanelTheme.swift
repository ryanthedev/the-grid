import SwiftUI
import AppKit

// Color palette unified with PickerColors. Monochromatic grays + cyan accent.
// Aesthetic direction: quiet, precise, utilitarian.
// Configurable via YAML; missing keys fall back to defaults.
struct NotificationPanelTheme {
    let background: Color
    let surface: Color
    let surfaceSelected: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentDim: Color
    let urgent: Color
    let pinned: Color
    let border: Color
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

    // Monochromatic base + cyan accent, unified with PickerColors.
    // Scheme: complementary pair -- cyan (#00BFFF, ~195 deg) for interactive,
    // muted coral (#B85C4A, ~15 deg) for urgency only. Everything else is neutral gray.
    static let `default` = NotificationPanelTheme(
        // #121212 -- matches PickerColors.background
        background: Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0),
        // #1A1A1A -- between picker bg and inputBackground
        surface: Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1A / 255.0),
        // #1E2A2E -- cyan-tinted gray, whisper of accent in selection
        surfaceSelected: Color(red: 0x1E / 255.0, green: 0x2A / 255.0, blue: 0x2E / 255.0),
        // #BFBFBF -- matches PickerColors.text
        textPrimary: Color(red: 0xBF / 255.0, green: 0xBF / 255.0, blue: 0xBF / 255.0),
        // #949494 -- matches PickerColors.textSecondary
        textSecondary: Color(red: 0x94 / 255.0, green: 0x94 / 255.0, blue: 0x94 / 255.0),
        // #7A7A7A -- matches PickerColors.textTertiary
        textTertiary: Color(red: 0x7A / 255.0, green: 0x7A / 255.0, blue: 0x7A / 255.0),
        // #00BFFF -- matches PickerColors.prompt (cyan)
        accent: Color(red: 0x00 / 255.0, green: 0xBF / 255.0, blue: 0xFF / 255.0),
        // #006B8F -- accent at ~45% brightness
        accentDim: Color(red: 0x00 / 255.0, green: 0x6B / 255.0, blue: 0x8F / 255.0),
        // #B85C4A -- complement of cyan (~15 deg), desaturated. Warm = advances.
        urgent: Color(red: 0xB8 / 255.0, green: 0x5C / 255.0, blue: 0x4A / 255.0),
        // #BFBFBF -- pin is structural (symbol), not chromatic
        pinned: Color(red: 0xBF / 255.0, green: 0xBF / 255.0, blue: 0xBF / 255.0),
        // #252525 -- barely-there separator
        border: Color(red: 0x25 / 255.0, green: 0x25 / 255.0, blue: 0x25 / 255.0),
        // #232323 -- matches PickerColors.inputBackground
        filterBackground: Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0),
        windowBackgroundNSColor: NSColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1.0)
    )

    // Convenience init from hex string dictionary (used by YAML config).
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
