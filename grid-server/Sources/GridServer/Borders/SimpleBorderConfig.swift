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
    private let lock = NSLock()

    // MARK: - Configurable Properties

    private var _enabled: Bool = true
    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    // Active border configuration (backing storage)
    private var _activeColor: CGColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)  // red
    private var _activeWidth: CGFloat = 3.0
    private var _activeCornerRadius: CGFloat = 8.0
    private var _activeOpacity: CGFloat = 1.0
    private var _activeGlowRadius: CGFloat? = nil
    private var _activeGlowColor: CGColor? = nil
    private var _activeGlowOpacity: CGFloat? = nil

    // Inactive border configuration (backing storage)
    private var _inactiveEnabled: Bool = true
    private var _inactiveColor: CGColor = CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)  // #666666
    private var _inactiveWidth: CGFloat = 3.0
    private var _inactiveCornerRadius: CGFloat = 8.0
    private var _inactiveOpacity: CGFloat = 1.0

    // Legacy properties (backing storage)
    private var _padding: CGFloat = 2.0
    private var _styleString: String = "round"
    private var _hidpi: Bool = true

    /// Callback invoked when config changes (for border refresh)
    private var _onConfigChanged: (() -> Void)?
    var onConfigChanged: (() -> Void)? {
        get { lock.withLock { _onConfigChanged } }
        set { lock.withLock { _onConfigChanged = newValue } }
    }

    /// Public padding accessor for BorderWindow access
    var padding: CGFloat {
        get { lock.withLock { _padding } }
        set { lock.withLock { _padding = newValue } }
    }

    private init() {}

    // MARK: - Computed Properties

    /// Active window border style
    var activeStyle: BorderStyle {
        lock.withLock {
            BorderStyle(
                color: _activeColor,
                width: _activeWidth,
                cornerRadius: _activeCornerRadius,
                opacity: _activeOpacity,
                styleType: parseStyleType(_styleString),
                glowRadius: _activeGlowRadius,
                glowColor: _activeGlowColor,
                glowOpacity: _activeGlowOpacity
            )
        }
    }

    /// Inactive window border style (nil if disabled)
    var inactiveStyle: BorderStyle? {
        lock.withLock {
            guard _inactiveEnabled else { return nil }
            return BorderStyle(
                color: _inactiveColor,
                width: _inactiveWidth,
                cornerRadius: _inactiveCornerRadius,
                opacity: _inactiveOpacity,
                styleType: parseStyleType(_styleString)
            )
        }
    }

    // MARK: - Configuration Update

    /// Update configuration from RPC params
    /// Supports both new nested schema and legacy flat schema
    func update(from config: [String: Any]) {
        let callback: (() -> Void)? = lock.withLock {
            if let enabled = config["enabled"] as? Bool {
                self._enabled = enabled
            }

            // New nested schema
            if let activeConfig = config["active"] as? [String: Any] {
                updateActiveStyleLocked(from: activeConfig)
            }

            if let inactiveConfig = config["inactive"] as? [String: Any] {
                updateInactiveStyleLocked(from: inactiveConfig)
            }

            // Legacy flat schema (backwards compatibility)
            if let width = (config["width"] as? NSNumber)?.doubleValue {
                self._activeWidth = clamp(CGFloat(width), min: 1, max: 20)
            }

            if let cornerRadius = (config["corner_radius"] as? NSNumber)?.doubleValue {
                self._activeCornerRadius = clamp(CGFloat(cornerRadius), min: 0, max: 50)
            }

            if let padding = (config["padding"] as? NSNumber)?.doubleValue {
                self._padding = CGFloat(padding)
            }

            if let style = config["style"] as? String {
                self._styleString = style
            }

            if let hidpi = config["hidpi"] as? Bool {
                self._hidpi = hidpi
            }

            // Legacy color parsing
            if let colorStr = config["active_window_color"] as? String {
                if let color = parseHexColor(colorStr) {
                    self._activeColor = color
                }
            }

            if let colorStr = config["inactive_color"] as? String {
                if let color = parseHexColor(colorStr) {
                    self._inactiveColor = color
                }
            }

            return self._onConfigChanged
        }

        // Notify listeners of config change (outside lock to prevent deadlock)
        callback?()
    }

    // MARK: - Private Helpers

    /// Update active border style from config dictionary (must be called with lock held)
    private func updateActiveStyleLocked(from config: [String: Any]) {
        if let colorStr = config["color"] as? String, let color = parseHexColor(colorStr) {
            self._activeColor = color
        }

        if let width = (config["width"] as? NSNumber)?.doubleValue {
            self._activeWidth = clamp(CGFloat(width), min: 1, max: 20)
        }

        if let cornerRadius = (config["cornerRadius"] as? NSNumber)?.doubleValue {
            self._activeCornerRadius = clamp(CGFloat(cornerRadius), min: 0, max: 50)
        }

        if let opacity = (config["opacity"] as? NSNumber)?.doubleValue {
            self._activeOpacity = clamp(CGFloat(opacity), min: 0, max: 1)
        }

        if let glowRadius = (config["glowRadius"] as? NSNumber)?.doubleValue {
            self._activeGlowRadius = CGFloat(glowRadius)
        }

        if let glowColorStr = config["glowColor"] as? String, let color = parseHexColor(glowColorStr) {
            self._activeGlowColor = color
        }

        if let glowOpacity = (config["glowOpacity"] as? NSNumber)?.doubleValue {
            self._activeGlowOpacity = clamp(CGFloat(glowOpacity), min: 0, max: 1)
        }
    }

    /// Update inactive border style from config dictionary (must be called with lock held)
    private func updateInactiveStyleLocked(from config: [String: Any]) {
        if let enabled = config["enabled"] as? Bool {
            self._inactiveEnabled = enabled
        }

        if let colorStr = config["color"] as? String, let color = parseHexColor(colorStr) {
            self._inactiveColor = color
        }

        if let width = (config["width"] as? NSNumber)?.doubleValue {
            self._inactiveWidth = clamp(CGFloat(width), min: 1, max: 20)
        }

        if let cornerRadius = (config["cornerRadius"] as? NSNumber)?.doubleValue {
            self._inactiveCornerRadius = clamp(CGFloat(cornerRadius), min: 0, max: 50)
        }

        if let opacity = (config["opacity"] as? NSNumber)?.doubleValue {
            self._inactiveOpacity = clamp(CGFloat(opacity), min: 0, max: 1)
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
