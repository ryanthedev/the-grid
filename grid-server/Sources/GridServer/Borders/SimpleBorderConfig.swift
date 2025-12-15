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

/// Simple border configuration with static defaults
struct SimpleBorderConfig {
    // MARK: - Cell Highlight (background overlay behind windows)

    /// Solid white background for cell highlight
    static let highlightFillColor: CGColor = CGColor(
        red: 1.0,
        green: 1.0,
        blue: 1.0,
        alpha: 0.6
    )

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
    static let windowBorderColor: CGColor = CGColor(
        red: 1.0,
        green: 0.0,
        blue: 0.0,
        alpha: 1.0
    )

    /// Border width for focused window
    static let windowBorderWidth: CGFloat = 3.0
}
