//
// PickerStyle.swift
// GridServer
//
// Visual configuration for the picker UI
//

import Foundation
import CoreGraphics
import AppKit

/// Visual style configuration for the picker
struct PickerStyle: Codable {
    // MARK: - Dimensions

    /// Width of the picker window
    var width: CGFloat

    /// Maximum number of visible items before scrolling
    var maxVisibleItems: Int

    /// Height of each item row
    var itemHeight: CGFloat

    /// Height of the input field area
    var inputHeight: CGFloat

    /// Padding around content
    var padding: CGFloat

    // MARK: - Typography

    /// Font name for text rendering
    var fontName: String

    /// Font size for item text
    var fontSize: CGFloat

    /// Font size for input text
    var inputFontSize: CGFloat

    // MARK: - Colors (stored as hex strings for Codable)

    /// Background color of the picker
    var backgroundColor: String

    /// Background color of the input field
    var inputBackgroundColor: String

    /// Primary text color
    var textColor: String

    /// Secondary/dimmed text color
    var secondaryTextColor: String

    /// Background color of selected item
    var selectedBackgroundColor: String

    /// Color for highlighting matched characters
    var matchHighlightColor: String

    /// Cursor/caret color
    var cursorColor: String

    /// Border color around the picker
    var borderColor: String

    // MARK: - Shape

    /// Corner radius of the picker window
    var cornerRadius: CGFloat

    /// Border width around the picker
    var borderWidth: CGFloat

    // MARK: - Defaults

    static var `default`: PickerStyle {
        PickerStyle(
            width: 600,
            maxVisibleItems: 10,
            itemHeight: 32,
            inputHeight: 40,
            padding: 8,
            fontName: "SF Mono",
            fontSize: 14,
            inputFontSize: 16,
            backgroundColor: "#1e1e2e",
            inputBackgroundColor: "#313244",
            textColor: "#cdd6f4",
            secondaryTextColor: "#6c7086",
            selectedBackgroundColor: "#45475a",
            matchHighlightColor: "#f9e2af",
            cursorColor: "#89b4fa",
            borderColor: "#585b70",
            cornerRadius: 12,
            borderWidth: 1
        )
    }

    // MARK: - Computed Properties

    /// Calculate total window height based on visible items
    func windowHeight(for itemCount: Int) -> CGFloat {
        let visibleCount = min(itemCount, maxVisibleItems)
        let listHeight = CGFloat(max(visibleCount, 1)) * itemHeight
        // inputHeight + padding + listHeight + padding + border
        return inputHeight + padding + listHeight + padding + borderWidth * 2
    }

    /// Calculate total window size
    func windowSize(for itemCount: Int) -> CGSize {
        CGSize(width: width, height: windowHeight(for: itemCount))
    }
}

// MARK: - Color Helpers

extension PickerStyle {

    /// Parse a hex color string to CGColor
    static func parseColor(_ hex: String) -> CGColor {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") {
            hexStr.removeFirst()
        }

        guard hexStr.count == 6, let rgb = UInt32(hexStr, radix: 16) else {
            // Fallback to white
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }

        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0

        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    var backgroundCGColor: CGColor { Self.parseColor(backgroundColor) }
    var inputBackgroundCGColor: CGColor { Self.parseColor(inputBackgroundColor) }
    var textCGColor: CGColor { Self.parseColor(textColor) }
    var secondaryTextCGColor: CGColor { Self.parseColor(secondaryTextColor) }
    var selectedBackgroundCGColor: CGColor { Self.parseColor(selectedBackgroundColor) }
    var matchHighlightCGColor: CGColor { Self.parseColor(matchHighlightColor) }
    var cursorCGColor: CGColor { Self.parseColor(cursorColor) }
    var borderCGColor: CGColor { Self.parseColor(borderColor) }
}

// MARK: - Picker State

/// Current state of the picker for rendering
struct PickerState {
    /// Current query string
    var query: String = ""

    /// Cursor position in query (character index)
    var cursorPosition: Int = 0

    /// All items (unfiltered)
    var allItems: [PickerItem] = []

    /// Filtered/matched items with scores
    var filteredItems: [MatchResult] = []

    /// Currently selected index in filtered items
    var selectedIndex: Int = 0

    /// Scroll offset (first visible item index)
    var scrollOffset: Int = 0

    /// Get the currently selected item, if any
    var selectedItem: PickerItem? {
        guard !filteredItems.isEmpty, selectedIndex >= 0, selectedIndex < filteredItems.count else {
            return nil
        }
        return filteredItems[selectedIndex].item
    }

    /// Move selection up
    mutating func selectPrevious() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        adjustScrollOffset()
    }

    /// Move selection down
    mutating func selectNext() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
        adjustScrollOffset()
    }

    /// Adjust scroll offset to keep selection visible
    mutating func adjustScrollOffset(maxVisible: Int = 10) {
        // Ensure selected item is visible
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + maxVisible {
            scrollOffset = selectedIndex - maxVisible + 1
        }
    }

    /// Reset selection after filter change
    mutating func resetSelection() {
        selectedIndex = 0
        scrollOffset = 0
    }
}
