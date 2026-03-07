//
// PickerViews.swift
// GridServer
//
// Visual components for the picker UI — ported from GridPicker/main.swift
// Renames: Colors→PickerColors, Fonts→PickerFonts, BackgroundView→PickerBackgroundView, ListView→PickerListView
//

import AppKit

// MARK: - PickerColors

/// Ghostty-inspired dark theme color constants
struct PickerColors {
    // #121212 - deep black background
    static let background = NSColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 0.98)
    // #232323 - slightly lighter for input area
    static let inputBackground = NSColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1)
    // #BFBFBF - neutral light gray text (primary)
    static let text = NSColor(red: 0.749, green: 0.749, blue: 0.749, alpha: 1)
    // #949494 - secondary text (subtitle) - readable, distinct from primary
    static let textSecondary = NSColor(red: 0.58, green: 0.58, blue: 0.58, alpha: 1)
    // #7A7A7A - tertiary text (preview) - softer but still comfortable
    static let textTertiary = NSColor(red: 0.478, green: 0.478, blue: 0.478, alpha: 1)
    // #666666 - dimmed placeholder (input hints only)
    static let placeholder = NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
    // #404040 - subtle border
    static let border = NSColor(red: 0.251, green: 0.251, blue: 0.251, alpha: 1)
    // #00BFFF - bright blue accent
    static let prompt = NSColor(red: 0.0, green: 0.749, blue: 1.0, alpha: 1)
}

// MARK: - PickerFonts

/// Font helpers for the picker UI
enum PickerFonts {
    /// Return a monospace font at the given size, preferring BerkeleyMono Nerd Font
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // Try BerkeleyMono Nerd Font first, fall back to system monospace
        if let font = NSFont(name: "BerkeleyMono Nerd Font", size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - NSLabel

/// Simple non-editable label helper
class NSLabel: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// MARK: - IconRenderer

/// Renders icon strings to NSImage for display in the picker
/// Supports: bundle IDs (bundle:com.apple.Safari), emoji, file paths, data URLs, and inline SVG
class IconRenderer {

    /// Target icon size in points
    static let targetSize: CGFloat = 24

    /// In-memory cache for rendered icons
    private static var cache: [String: NSImage] = [:]

    /// Render an icon string to an NSImage
    /// - Parameter iconString: Icon value (emoji, file path, data:base64, or inline SVG)
    /// - Returns: Rendered NSImage or nil if invalid/missing
    static func render(_ iconString: String?) -> NSImage? {
        guard let icon = iconString, !icon.isEmpty else {
            return nil
        }

        // Check cache first
        if let cached = cache[icon] {
            return cached
        }

        // Detect format and render
        let image = detectAndRender(icon)

        // Cache successful renders
        if let image = image {
            cache[icon] = image
        }

        return image
    }

    /// Detect icon format and render appropriately
    private static func detectAndRender(_ icon: String) -> NSImage? {
        // Bundle identifier (app icon lookup)
        if icon.hasPrefix("bundle:") {
            return loadFromBundle(icon)
        }

        // Data URL (base64 encoded image)
        if icon.hasPrefix("data:image/") {
            return renderDataURL(icon)
        }

        // Inline SVG
        if icon.hasPrefix("<svg") || icon.hasPrefix("<?xml") {
            return renderSVG(icon)
        }

        // File path
        if isFilePath(icon) {
            return loadFromFile(icon)
        }

        // Single grapheme cluster (emoji)
        if icon.count == 1 || (icon.unicodeScalars.count > 1 && icon.count == 1) {
            return renderEmoji(icon)
        }

        // Check if it's a short string that looks like an emoji (handles ZWJ sequences)
        if isLikelyEmoji(icon) {
            return renderEmoji(icon)
        }

        return nil
    }

    /// Load app icon from bundle identifier
    /// - Parameter icon: Icon string starting with "bundle:" prefix
    /// - Returns: App icon NSImage or nil if bundle not found
    private static func loadFromBundle(_ icon: String) -> NSImage? {
        // Extract bundle identifier (drop "bundle:" prefix - 7 chars)
        let bundleID = String(icon.dropFirst(7))

        guard !bundleID.isEmpty else {
            return nil
        }

        // Resolve app URL from bundle identifier
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        // Get app icon
        let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        return scaleImage(appIcon, to: targetSize)
    }

    /// Check if string appears to be a file path
    private static func isFilePath(_ icon: String) -> Bool {
        // Starts with path indicators
        if icon.hasPrefix("/") || icon.hasPrefix("~") || icon.hasPrefix("./") {
            return true
        }

        // Ends with image extension
        let lowercased = icon.lowercased()
        let imageExtensions = [".svg", ".png", ".jpg", ".jpeg", ".gif"]
        return imageExtensions.contains { lowercased.hasSuffix($0) }
    }

    /// Check if string is likely an emoji (handles complex emoji like flags, ZWJ sequences)
    private static func isLikelyEmoji(_ icon: String) -> Bool {
        // Must be short (most emoji are 1-2 grapheme clusters, ZWJ sequences can be longer)
        guard icon.count <= 7 else { return false }

        // Check if all characters are emoji-like
        for scalar in icon.unicodeScalars {
            let value = scalar.value
            // Allow: emoji ranges, variation selectors, ZWJ, skin tone modifiers
            let isEmojiLike = (value >= 0x1F300 && value <= 0x1FAD6) ||  // Misc symbols, emoticons, etc.
                              (value >= 0x2600 && value <= 0x26FF) ||    // Misc symbols
                              (value >= 0x2700 && value <= 0x27BF) ||    // Dingbats
                              (value >= 0x1F600 && value <= 0x1F64F) ||  // Emoticons
                              (value >= 0x1F680 && value <= 0x1F6FF) ||  // Transport/map
                              (value >= 0x1F1E0 && value <= 0x1F1FF) ||  // Regional indicators (flags)
                              value == 0xFE0F ||                          // Variation selector
                              value == 0x200D ||                          // ZWJ
                              (value >= 0x1F3FB && value <= 0x1F3FF)      // Skin tone modifiers
            if !isEmojiLike {
                return false
            }
        }
        return true
    }

    /// Render emoji character to NSImage
    private static func renderEmoji(_ emoji: String) -> NSImage? {
        let size = NSSize(width: targetSize, height: targetSize)

        // Create attributed string with emoji
        let fontSize = targetSize * 0.85
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]
        let attributedString = NSAttributedString(string: emoji, attributes: attributes)

        // Calculate text size for centering
        let textSize = attributedString.size()

        // Create image
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw centered
        let x = (size.width - textSize.width) / 2
        let y = (size.height - textSize.height) / 2
        attributedString.draw(at: NSPoint(x: x, y: y))

        image.unlockFocus()
        return image
    }

    /// Load image from file path
    private static func loadFromFile(_ path: String) -> NSImage? {
        // Expand tilde
        let expandedPath = (path as NSString).expandingTildeInPath

        guard let image = NSImage(contentsOfFile: expandedPath) else {
            return nil
        }

        return scaleImage(image, to: targetSize)
    }

    /// Render base64 data URL to NSImage
    private static func renderDataURL(_ dataURL: String) -> NSImage? {
        // Find base64 data after "base64,"
        guard let base64Range = dataURL.range(of: "base64,") else {
            return nil
        }

        let base64String = String(dataURL[base64Range.upperBound...])

        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            return nil
        }

        guard let image = NSImage(data: data) else {
            return nil
        }

        return scaleImage(image, to: targetSize)
    }

    /// Render inline SVG to NSImage
    private static func renderSVG(_ svgString: String) -> NSImage? {
        guard let data = svgString.data(using: .utf8) else {
            return nil
        }

        guard let image = NSImage(data: data) else {
            return nil
        }

        return scaleImage(image, to: targetSize)
    }

    /// Scale an image to fit within target size while maintaining aspect ratio
    private static func scaleImage(_ image: NSImage, to targetSize: CGFloat) -> NSImage {
        let originalSize = image.size

        // Guard against malformed images with zero dimensions
        guard originalSize.width > 0 && originalSize.height > 0 else {
            return image
        }

        // Calculate scale factor to fit within target size
        let scale = min(targetSize / originalSize.width, targetSize / originalSize.height)
        let newSize = NSSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )

        // Create new image at target size
        let newImage = NSImage(size: NSSize(width: targetSize, height: targetSize))
        newImage.lockFocus()

        // Draw centered
        let x = (targetSize - newSize.width) / 2
        let y = (targetSize - newSize.height) / 2
        image.draw(
            in: NSRect(x: x, y: y, width: newSize.width, height: newSize.height),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )

        newImage.unlockFocus()
        return newImage
    }

    /// Clear the icon cache (useful for testing or memory management)
    static func clearCache() {
        cache.removeAll()
    }
}

// MARK: - PickerBackgroundView

/// Rounded rect background view with border stroke
class PickerBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)

        PickerColors.background.setFill()
        path.fill()

        PickerColors.border.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - ListItemView

/// A single row in the picker list - styled as a card
class ListItemView: NSView {
    private let item: PickerItem
    private let matchedIndices: Set<Int>
    private let isSelected: Bool
    private let showIconColumn: Bool

    // Layout constants (scaled +20% for larger fonts, more breathing room)
    private static let verticalPadding: CGFloat = 12
    private static let titleLineHeight: CGFloat = 24
    private static let subtitleLineHeight: CGFloat = 20
    private static let previewLineHeight: CGFloat = 18
    private static let iconColumnWidth: CGFloat = 48
    private static let horizontalPadding: CGFloat = 16

    // Card styling
    private static let cardCornerRadius: CGFloat = 6
    private static let cardInset: CGFloat = 8
    static let itemGap: CGFloat = 6

    // Minimum height for title-only items
    static let itemHeight: CGFloat = 48

    /// Calculate height for a specific item based on its content
    static func heightForItem(_ item: PickerItem) -> CGFloat {
        var height: CGFloat = verticalPadding * 2 + titleLineHeight
        if item.subtitle != nil {
            height += subtitleLineHeight
        }
        if item.preview != nil {
            height += previewLineHeight
        }
        return height + itemGap
    }

    init(item: PickerItem, matchedIndices: [Int], isSelected: Bool, showIconColumn: Bool) {
        self.item = item
        self.matchedIndices = Set(matchedIndices)
        self.isSelected = isSelected
        self.showIconColumn = showIconColumn
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds

        // Card area (inset from full bounds, accounting for gap)
        let cardRect = NSRect(
            x: Self.cardInset,
            y: Self.itemGap,
            width: bounds.width - Self.cardInset * 2,
            height: bounds.height - Self.itemGap
        )

        // Draw card background (subtle differentiation)
        let cardBg = isSelected ? PickerColors.inputBackground : PickerColors.inputBackground.withAlphaComponent(0.3)
        cardBg.setFill()
        NSBezierPath(roundedRect: cardRect, xRadius: Self.cardCornerRadius, yRadius: Self.cardCornerRadius).fill()

        // Text starts at left padding within card
        let textStartX = Self.cardInset + Self.horizontalPadding

        // Text ends before icon column (icon now on right) with margin
        let iconMargin: CGFloat = 12
        let textEndX: CGFloat
        if showIconColumn {
            textEndX = bounds.width - Self.cardInset - Self.horizontalPadding - Self.iconColumnWidth - iconMargin
        } else {
            textEndX = bounds.width - Self.cardInset - Self.horizontalPadding
        }
        let textWidth = textEndX - textStartX

        // Draw icon on RIGHT side if present
        if showIconColumn, let iconImage = IconRenderer.render(item.icon) {
            let iconSize = IconRenderer.targetSize
            let iconX = bounds.width - Self.cardInset - Self.horizontalPadding - iconSize
            let iconY = cardRect.midY - iconSize / 2
            iconImage.draw(in: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
        }

        // Track Y position (drawing from top to bottom, but NSView coordinates are bottom-up)
        var currentY = cardRect.maxY - Self.verticalPadding

        // Draw title with highlighting (truncated to fit)
        let titleString = buildTitleAttributedString()
        currentY -= Self.titleLineHeight
        let titleRect = NSRect(x: textStartX, y: currentY, width: textWidth, height: Self.titleLineHeight)
        titleString.draw(in: titleRect)

        // Draw subtitle if present (truncated to fit)
        if let subtitle = item.subtitle {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail

            let subtitleString = NSAttributedString(
                string: subtitle,
                attributes: [
                    .font: PickerFonts.mono(size: 14),
                    .foregroundColor: PickerColors.textSecondary,
                    .paragraphStyle: paragraphStyle
                ]
            )
            currentY -= Self.subtitleLineHeight
            let subtitleRect = NSRect(x: textStartX, y: currentY, width: textWidth, height: Self.subtitleLineHeight)
            subtitleString.draw(in: subtitleRect)
        }

        // Draw preview if present (truncated)
        if let preview = item.preview {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail

            let previewString = NSAttributedString(
                string: preview,
                attributes: [
                    .font: PickerFonts.mono(size: 13),
                    .foregroundColor: PickerColors.textTertiary,
                    .paragraphStyle: paragraphStyle
                ]
            )
            currentY -= Self.previewLineHeight
            let previewRect = NSRect(x: textStartX, y: currentY, width: textWidth, height: Self.previewLineHeight)
            previewString.draw(in: previewRect)
        }
    }

    /// Build the title attributed string with match highlighting
    private func buildTitleAttributedString() -> NSAttributedString {
        let displayText = item.title
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributedString = NSMutableAttributedString(
            string: displayText,
            attributes: [
                .font: PickerFonts.mono(size: 17),
                .foregroundColor: PickerColors.text,
                .paragraphStyle: paragraphStyle
            ]
        )

        // Highlight matched characters with accent color
        // Convert Character indices to UTF-16 ranges for NSAttributedString
        let characters = Array(displayText)
        for charIndex in matchedIndices {
            if charIndex < characters.count {
                // Calculate UTF-16 offset for this character index
                let prefix = String(characters[0..<charIndex])
                let utf16Start = prefix.utf16.count
                let charUtf16Length = String(characters[charIndex]).utf16.count
                let range = NSRange(location: utf16Start, length: charUtf16Length)
                attributedString.addAttribute(.foregroundColor, value: PickerColors.prompt, range: range)
            }
        }

        return attributedString
    }
}

// MARK: - PickerListView

/// Container view for the picker list items
class PickerListView: NSView {
    private weak var state: PickerState?
    private var itemViews: [ListItemView] = []

    init(state: PickerState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Check if ANY item in the filtered results has an icon
    /// This determines whether to show icon column for ALL items (consistent layout)
    var hasAnyIcons: Bool {
        guard let state = state else { return false }
        return state.filteredResults.contains { $0.item.icon != nil }
    }

    /// Refresh the list view based on current state
    func refresh() {
        // Remove old views
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        guard let state = state else { return }

        let visibleResults = state.visibleResults
        let showIconColumn = hasAnyIcons

        // Track cumulative Y offset for variable height positioning
        var cumulativeY: CGFloat = 0

        for (viewIndex, result) in visibleResults.enumerated() {
            let actualIndex = state.scrollOffset + viewIndex
            let isSelected = actualIndex == state.selectedIndex
            let itemHeight = ListItemView.heightForItem(result.item)

            let itemView = ListItemView(
                item: result.item,
                matchedIndices: result.matchedIndices,
                isSelected: isSelected,
                showIconColumn: showIconColumn
            )
            itemView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(itemView)
            itemViews.append(itemView)

            NSLayoutConstraint.activate([
                itemView.leadingAnchor.constraint(equalTo: leadingAnchor),
                itemView.trailingAnchor.constraint(equalTo: trailingAnchor),
                itemView.topAnchor.constraint(equalTo: topAnchor, constant: cumulativeY),
                itemView.heightAnchor.constraint(equalToConstant: itemHeight)
            ])

            cumulativeY += itemHeight
        }
    }

    /// Calculate required height based on visible items (variable heights)
    var requiredHeight: CGFloat {
        guard let state = state else { return 0 }
        let visibleResults = state.visibleResults
        return visibleResults.reduce(0) { $0 + ListItemView.heightForItem($1.item) }
    }

    /// Show "No matches" message when filtered results are empty but items exist
    var shouldShowEmptyMessage: Bool {
        guard let state = state else { return false }
        return state.hasItems && state.filteredResults.isEmpty
    }
}
