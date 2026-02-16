//
// grid-picker
//
// Standalone input picker with clean CLI API
//
// Usage:
//   grid-picker [--prompt "text"] [--width N] [--height N]
//
// Output (stdout):
//   {"text": "user input", "cancelled": false}
//   {"text": "", "cancelled": true}
//
// Exit codes:
//   0 = submitted (Enter)
//   1 = cancelled (ESC, Close, focus loss)
//

import AppKit

// MARK: - Daemon Mode

/// Whether running as persistent daemon (socket mode) vs one-shot (stdin mode)
var isDaemonMode = false

/// Socket and PID file paths for daemon mode
let pickerSocketPath = NSString("~/.local/state/thegrid/grid-picker.sock").expandingTildeInPath
let pickerPIDPath = NSString("~/.local/state/thegrid/grid-picker.pid").expandingTildeInPath

// MARK: - Data Models

/// A single item that can be displayed and selected in the picker
struct PickerItem: Codable, Equatable {
    /// Unique identifier for this item
    let id: String

    /// Primary text shown in the picker (required)
    let title: String

    /// Secondary line (path, description)
    let subtitle: String?

    /// Third line excerpt
    let preview: String?

    /// Icon value (emoji, file path, data:base64, or inline SVG)
    let icon: String?

    /// Additional strings to search against (e.g., description, path, tags)
    let searchable: [String]

    /// Optional metadata passed back on selection (picker ignores this)
    let metadata: [String: String]?

    /// Priority for sorting (higher = appears first when match scores are equal)
    let priority: Int

    /// Display text shown in the picker (backwards compatibility, returns title)
    var display: String {
        title
    }

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        preview: String? = nil,
        icon: String? = nil,
        searchable: [String]? = nil,
        metadata: [String: String]? = nil,
        priority: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.icon = icon
        self.searchable = searchable ?? [title]
        self.metadata = metadata
        self.priority = priority
    }

    /// Custom Decodable init to handle both old format (display) and new format (title + optional fields)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        // Backwards compatibility: prefer title, fallback to display
        if let titleValue = try container.decodeIfPresent(String.self, forKey: .title) {
            title = titleValue
        } else {
            title = try container.decode(String.self, forKey: .display)
        }

        // New optional fields
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)

        // Existing optional fields
        let optionalSearchable = try container.decodeIfPresent([String].self, forKey: .searchable)
        searchable = optionalSearchable ?? [title]
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    /// Custom Encodable to include display field for backwards compatibility
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        // Include display for backwards compatibility
        try container.encode(title, forKey: .display)
        try container.encode(searchable, forKey: .searchable)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(priority, forKey: .priority)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, display, subtitle, preview, icon, searchable, metadata, priority
    }

    /// Get all searchable text (title + searchable + subtitle + preview when present)
    var allSearchableText: [String] {
        var texts = [title] + searchable
        if let subtitle = subtitle {
            texts.append(subtitle)
        }
        if let preview = preview {
            texts.append(preview)
        }
        return texts
    }
}

// MARK: - Icon Rendering

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

// MARK: - Fuzzy Matching

/// Result of matching a query against an item
struct MatchResult {
    /// The matched item
    let item: PickerItem

    /// Match score (higher = better match)
    let score: Int

    /// Indices of matched characters in the display string (for highlighting)
    let matchedIndices: [Int]
}

/// Fuzzy matcher for filtering picker items
enum FuzzyMatcher {

    /// Field type for weighted scoring
    private enum FieldType {
        case title
        case subtitle
        case preview
        case searchable

        /// Weight multiplier for this field type
        /// Title: 100%, Subtitle: 70%, Preview: 50%, Searchable: 100% (same as title)
        var weight: Double {
            switch self {
            case .title, .searchable: return 1.0
            case .subtitle: return 0.7
            case .preview: return 0.5
            }
        }
    }

    /// Match a query against a list of items
    /// - Parameters:
    ///   - query: The search query
    ///   - items: Items to search
    /// - Returns: Matched items sorted by score (descending)
    static func match(query: String, items: [PickerItem]) -> [MatchResult] {
        // Empty query returns all items with default score
        guard !query.isEmpty else {
            return items.map { MatchResult(item: $0, score: 0, matchedIndices: []) }
        }

        // Determine case sensitivity (smart case: case-insensitive unless query has uppercase)
        let caseSensitive = query.contains(where: { $0.isUppercase })

        var results: [MatchResult] = []

        for item in items {
            // Build list of (text, fieldType) pairs for searching
            var searchFields: [(text: String, fieldType: FieldType)] = []

            // Title is always first and primary
            searchFields.append((item.title, .title))

            // Subtitle if present
            if let subtitle = item.subtitle {
                searchFields.append((subtitle, .subtitle))
            }

            // Preview if present
            if let preview = item.preview {
                searchFields.append((preview, .preview))
            }

            // Additional searchable strings (excluding title which is already included)
            for searchText in item.searchable where searchText != item.title {
                searchFields.append((searchText, .searchable))
            }

            // Track best weighted score and title match indices separately
            var bestWeightedScore = Int.min
            var titleMatchIndices: [Int] = []
            var hasAnyMatch = false

            for (text, fieldType) in searchFields {
                if let (rawScore, indices) = matchSingle(
                    query: query,
                    text: text,
                    caseSensitive: caseSensitive
                ) {
                    hasAnyMatch = true

                    // Apply field weight to raw score
                    let weightedScore = Int(Double(rawScore) * fieldType.weight)

                    if weightedScore > bestWeightedScore {
                        bestWeightedScore = weightedScore
                    }

                    // Capture title match indices for highlighting (prefer title even if not highest score)
                    if fieldType == .title {
                        titleMatchIndices = indices
                    }
                }
            }

            if hasAnyMatch {
                // Add priority bonus to score (priority/3 gives strong boost)
                // e.g., windows (priority=1000) get +333, profiles (priority=100) get +33
                let priorityBonus = item.priority / 3
                results.append(MatchResult(
                    item: item,
                    score: bestWeightedScore + priorityBonus,
                    matchedIndices: titleMatchIndices
                ))
            }
        }

        // Sort by score descending, then by display text ascending for ties
        return results.sorted { (lhs: MatchResult, rhs: MatchResult) -> Bool in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.item.display < rhs.item.display
        }
    }

    /// Match a single query against a single text
    /// - Parameters:
    ///   - query: Search query
    ///   - text: Text to search in
    ///   - caseSensitive: Whether to match case-sensitively
    /// - Returns: (score, matched indices) or nil if no match
    private static func matchSingle(
        query: String,
        text: String,
        caseSensitive: Bool
    ) -> (Int, [Int])? {
        // Normalize separators: treat hyphens, underscores as spaces
        let normalizedQuery = query.replacingOccurrences(of: "-", with: " ")
                                   .replacingOccurrences(of: "_", with: " ")
        let normalizedText = text.replacingOccurrences(of: "-", with: " ")
                                 .replacingOccurrences(of: "_", with: " ")

        let queryChars = caseSensitive ? Array(normalizedQuery) : Array(normalizedQuery.lowercased())
        let textChars = caseSensitive ? Array(normalizedText) : Array(normalizedText.lowercased())
        let originalTextChars = Array(text)

        var queryIndex = 0
        var matchedIndices: [Int] = []
        var score = 0

        // Track consecutive matches for bonus
        var consecutiveCount = 0
        var lastMatchIndex = -2

        for (textIndex, char) in textChars.enumerated() {
            guard queryIndex < queryChars.count else { break }

            if char == queryChars[queryIndex] {
                matchedIndices.append(textIndex)

                // Base score for a match
                var matchScore = 10

                // Bonus for consecutive matches
                if textIndex == lastMatchIndex + 1 {
                    consecutiveCount += 1
                    matchScore += consecutiveCount * 5
                } else {
                    consecutiveCount = 0
                }

                // Bonus for word boundary match
                if textIndex == 0 || !originalTextChars[textIndex - 1].isLetter {
                    matchScore += 15
                }

                // Bonus for camelCase match
                if textIndex > 0 && originalTextChars[textIndex].isUppercase &&
                   originalTextChars[textIndex - 1].isLowercase {
                    matchScore += 10
                }

                // Bonus for matching at start
                if textIndex == 0 {
                    matchScore += 20
                }

                // Penalty for later matches
                matchScore -= textIndex / 5

                score += matchScore
                lastMatchIndex = textIndex
                queryIndex += 1
            }
        }

        // All query characters must match
        guard queryIndex == queryChars.count else { return nil }

        // Bonus for shorter text (tighter match)
        score += max(0, 100 - text.count)

        // Bonus for exact match
        if caseSensitive ? text == query : text.lowercased() == query.lowercased() {
            score += 500
        }

        // Bonus for prefix match
        if caseSensitive ? text.hasPrefix(query) : text.lowercased().hasPrefix(query.lowercased()) {
            score += 200
        }

        return (score, matchedIndices)
    }
}

// MARK: - Picker State

/// Observable state for the picker UI
class PickerState {
    /// All items (unchanging after init)
    private(set) var allItems: [PickerItem]

    /// Current search query
    private(set) var query: String = ""

    /// Filtered and scored results
    private(set) var filteredResults: [MatchResult] = []

    /// Currently selected index (within filtered results)
    private(set) var selectedIndex: Int = 0

    /// Scroll offset (first visible item index)
    private(set) var scrollOffset: Int = 0

    /// Maximum height for the list area (in points)
    /// With variable item heights (36-70pt), use height constraint instead of item count
    static let maxListHeight: CGFloat = 600

    /// Callback when state changes
    var onStateChange: (() -> Void)?

    init(items: [PickerItem]) {
        self.allItems = items
        self.filteredResults = FuzzyMatcher.match(query: "", items: items)
    }

    /// Update the search query and refilter items
    func updateQuery(_ newQuery: String) {
        query = newQuery
        filteredResults = FuzzyMatcher.match(query: newQuery, items: allItems)
        selectedIndex = 0
        scrollOffset = 0
        onStateChange?()
    }

    /// Move selection by delta (positive = down, negative = up)
    func moveSelection(_ delta: Int) {
        guard !filteredResults.isEmpty else { return }

        let newIndex = selectedIndex + delta
        selectedIndex = max(0, min(newIndex, filteredResults.count - 1))

        // Adjust scroll offset to keep selection visible
        if selectedIndex < scrollOffset {
            // Selection moved above visible area
            scrollOffset = selectedIndex
        } else {
            // Check if selection is below visible area
            // Calculate visible item count from current scroll offset
            let visibleCount = countVisibleItemsFrom(scrollOffset)
            if selectedIndex >= scrollOffset + visibleCount {
                // Need to scroll down - find new scroll offset that makes selection visible
                // Start from selection and work backwards to find scroll offset
                scrollOffset = findScrollOffsetToShow(selectedIndex)
            }
        }

        onStateChange?()
    }

    /// Find the scroll offset that would show the given index at the bottom of the visible area
    private func findScrollOffsetToShow(_ targetIndex: Int) -> Int {
        // Start from targetIndex and work backwards
        // Include items until we would exceed max height
        var accumulatedHeight: CGFloat = 0
        var startIndex = targetIndex

        for i in stride(from: targetIndex, through: 0, by: -1) {
            let itemHeight = ListItemView.heightForItem(filteredResults[i].item)

            if accumulatedHeight + itemHeight > Self.maxListHeight {
                // This item would exceed max height, stop at previous
                break
            }

            accumulatedHeight += itemHeight
            startIndex = i
        }

        return startIndex
    }

    /// Get the currently selected item, if any
    var selectedItem: PickerItem? {
        guard !filteredResults.isEmpty, selectedIndex < filteredResults.count else {
            return nil
        }
        return filteredResults[selectedIndex].item
    }

    /// Get the currently selected match result (includes indices for highlighting)
    var selectedResult: MatchResult? {
        guard !filteredResults.isEmpty, selectedIndex < filteredResults.count else {
            return nil
        }
        return filteredResults[selectedIndex]
    }

    /// Get visible results based on scroll offset and max list height
    /// Uses variable item heights to determine how many items fit
    var visibleResults: [MatchResult] {
        guard scrollOffset < filteredResults.count else { return [] }

        var results: [MatchResult] = []
        var accumulatedHeight: CGFloat = 0

        for i in scrollOffset..<filteredResults.count {
            let result = filteredResults[i]
            let itemHeight = ListItemView.heightForItem(result.item)

            // Always include at least one item
            if results.isEmpty {
                results.append(result)
                accumulatedHeight += itemHeight
                continue
            }

            // Check if adding this item would exceed max height
            if accumulatedHeight + itemHeight > Self.maxListHeight {
                break
            }

            results.append(result)
            accumulatedHeight += itemHeight
        }

        return results
    }

    /// Calculate how many items fit starting from a given index (for scroll calculations)
    private func countVisibleItemsFrom(_ startIndex: Int) -> Int {
        guard startIndex < filteredResults.count else { return 0 }

        var count = 0
        var accumulatedHeight: CGFloat = 0

        for i in startIndex..<filteredResults.count {
            let itemHeight = ListItemView.heightForItem(filteredResults[i].item)

            // Always include at least one item
            if count == 0 {
                count += 1
                accumulatedHeight += itemHeight
                continue
            }

            if accumulatedHeight + itemHeight > Self.maxListHeight {
                break
            }

            count += 1
            accumulatedHeight += itemHeight
        }

        return count
    }

    /// Check if there are items to display
    var hasItems: Bool {
        !allItems.isEmpty
    }

    /// Check if we're in list mode (have items) vs simple input mode
    var isListMode: Bool {
        hasItems
    }

    /// Reset state with new items (for daemon mode window reuse)
    func resetWithItems(_ items: [PickerItem]) {
        allItems = items
        query = ""
        filteredResults = FuzzyMatcher.match(query: "", items: items)
        selectedIndex = 0
        scrollOffset = 0
        onStateChange?()
    }
}

// MARK: - List Item View

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
        let cardBg = isSelected ? Colors.inputBackground : Colors.inputBackground.withAlphaComponent(0.3)
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
                    .font: Fonts.mono(size: 14),
                    .foregroundColor: Colors.textSecondary,
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
                    .font: Fonts.mono(size: 13),
                    .foregroundColor: Colors.textTertiary,
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
                .font: Fonts.mono(size: 17),
                .foregroundColor: Colors.text,
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
                attributedString.addAttribute(.foregroundColor, value: Colors.prompt, range: range)
            }
        }

        return attributedString
    }
}

// MARK: - List View

/// Container view for the picker list items
class ListView: NSView {
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

// MARK: - Configuration

struct PickerConfig {
    var prompt: String = ""
    var width: CGFloat = 800
    var height: CGFloat = 56
    var items: [PickerItem] = []
    var testQuery: String? = nil

    static func parse(_ args: [String]) -> PickerConfig {
        var config = PickerConfig()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--prompt":
                if i + 1 < args.count {
                    config.prompt = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--width":
                if i + 1 < args.count, let w = Double(args[i + 1]) {
                    config.width = CGFloat(w)
                    i += 2
                } else {
                    i += 1
                }
            case "--height":
                if i + 1 < args.count, let h = Double(args[i + 1]) {
                    config.height = CGFloat(h)
                    i += 2
                } else {
                    i += 1
                }
            case "--test":
                if i + 1 < args.count {
                    config.testQuery = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                i += 1
            }
        }
        return config
    }
}

func printUsage() {
    let usage = """
    grid-picker - Standalone input picker

    Usage:
      grid-picker [options]

    Options:
      --prompt TEXT   Prompt text shown before input
      --width N       Window width in pixels (default: 400)
      --height N      Window height in pixels (default: 56)
      --test QUERY    Test mode: output matching results as JSON (no GUI)
      --help, -h      Show this help

    Output (JSON to stdout):
      {"text": "user input", "cancelled": false}

    Exit codes:
      0 = submitted (Enter)
      1 = cancelled (ESC, Close, or focus loss)
    """
    fputs(usage + "\n", stderr)
}

// MARK: - Result Handling

enum PickerResult {
    case submitted(String)
    case selected(PickerItem)
    case cancelled

    var exitCode: Int32 {
        switch self {
        case .submitted, .selected: return 0
        case .cancelled: return 1
        }
    }

    var json: String {
        switch self {
        case .submitted(let text):
            let escaped = escapeJSON(text)
            return "{\"text\": \"\(escaped)\", \"cancelled\": false}"
        case .selected(let item):
            return formatSelectedItem(item)
        case .cancelled:
            return "{\"text\": \"\", \"cancelled\": true}"
        }
    }

    private func escapeJSON(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func formatSelectedItem(_ item: PickerItem) -> String {
        var selectedDict: [String: Any] = [
            "id": item.id,
            "title": item.title,
            // Include display for backwards compatibility
            "display": item.display,
            "searchable": item.searchable
        ]
        if let subtitle = item.subtitle {
            selectedDict["subtitle"] = subtitle
        }
        if let preview = item.preview {
            selectedDict["preview"] = preview
        }
        if let icon = item.icon {
            selectedDict["icon"] = icon
        }
        if let metadata = item.metadata {
            selectedDict["metadata"] = metadata
        }

        let result: [String: Any] = [
            "cancelled": false,
            "selected": selectedDict
        ]

        // Use JSONSerialization for proper encoding
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }

        // Fallback to manual construction
        let escaped = escapeJSON(item.display)
        return "{\"cancelled\": false, \"selected\": {\"id\": \"\(escapeJSON(item.id))\", \"title\": \"\(escaped)\", \"display\": \"\(escaped)\"}}"
    }
}

func finish(_ result: PickerResult) {
    if isDaemonMode {
        hideAndRespond(result)
    } else {
        print(result.json)
        exit(result.exitCode)
    }
}

func hideAndRespond(_ result: PickerResult) {
    guard let delegate = NSApp.delegate as? AppDelegate else { return }
    guard let conn = delegate.activeConnection else { return }
    delegate.socketListener?.sendResponse(result, to: conn)
    delegate.activeConnection = nil
    delegate.window?.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
}

// MARK: - Colors (Ghostty-inspired dark theme)

struct Colors {
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

// MARK: - Fonts

enum Fonts {
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // Try BerkeleyMono Nerd Font first, fall back to system monospace
        if let font = NSFont(name: "BerkeleyMono Nerd Font", size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Window

class PickerWindow: NSWindow {
    private let textField: NSTextField
    private let promptLabel: NSLabel
    private let closeButton: NSButton
    private let config: PickerConfig
    private let emptyLabel: NSLabel

    // List mode components
    private var state: PickerState?
    private var listView: ListView?
    private var listViewHeightConstraint: NSLayoutConstraint?

    // Layout constants
    private static let inputHeight: CGFloat = 68
    private static let listPadding: CGFloat = 8

    init(config: PickerConfig) {
        self.config = config

        // Create text field
        textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = Fonts.mono(size: 19)
        textField.textColor = Colors.text

        // Create prompt label
        promptLabel = NSLabel()
        promptLabel.stringValue = config.prompt
        promptLabel.font = Fonts.mono(size: 19)
        promptLabel.textColor = Colors.prompt
        promptLabel.isHidden = config.prompt.isEmpty

        // Create close button
        closeButton = NSButton(title: "✕", target: nil, action: nil)
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = Colors.placeholder

        // Create empty state label
        emptyLabel = NSLabel()
        emptyLabel.stringValue = "No matches"
        emptyLabel.font = Fonts.mono(size: 17)
        emptyLabel.textColor = Colors.placeholder
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // Initialize state if we have items

        let pickerState: PickerState?
        if !config.items.isEmpty {
            pickerState = PickerState(items: config.items)
        } else {
            pickerState = nil
        }
        self.state = pickerState


        // Calculate initial window size (inline to avoid self usage before super.init)
        // Fixed height: always use maxListHeight for consistent window size (no shifting on filter)
        let initialHeight: CGFloat
        if let st = pickerState, st.hasItems {
            initialHeight = Self.inputHeight + PickerState.maxListHeight + Self.listPadding
        } else {
            initialHeight = Self.inputHeight
        }

        // Calculate position - center on screen
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fatalError("No screens available")
        }
        let origin = NSPoint(
            x: screen.frame.midX - config.width / 2,
            y: screen.frame.midY - initialHeight / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: CGSize(width: config.width, height: initialHeight)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )


        setupWindow()
        setupContentView()
        setupLayout()

        setupActions()
        setupStateObserver()
    }

    private func setupWindow() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        acceptsMouseMovedEvents = true
    }

    private func setupContentView() {
        let bgView = BackgroundView()
        contentView = bgView
    }

    private func setupLayout() {
        guard let bgView = contentView else { return }

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        bgView.addSubview(promptLabel)
        bgView.addSubview(textField)
        bgView.addSubview(closeButton)
        bgView.addSubview(emptyLabel)

        let padding: CGFloat = 16

        // Input row layout (top of window)
        if config.prompt.isEmpty {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
                textField.topAnchor.constraint(equalTo: bgView.topAnchor, constant: padding),
                textField.heightAnchor.constraint(equalToConstant: Self.inputHeight - padding * 2),
                textField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            ])
        } else {
            NSLayoutConstraint.activate([
                promptLabel.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
                promptLabel.topAnchor.constraint(equalTo: bgView.topAnchor, constant: padding),
                promptLabel.heightAnchor.constraint(equalToConstant: Self.inputHeight - padding * 2),

                textField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 8),
                textField.topAnchor.constraint(equalTo: bgView.topAnchor, constant: padding),
                textField.heightAnchor.constraint(equalToConstant: Self.inputHeight - padding * 2),
                textField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            ])
        }

        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            closeButton.topAnchor.constraint(equalTo: bgView.topAnchor, constant: padding),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: Self.inputHeight - padding * 2),
        ])

        // Empty label (shown when no matches)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
            emptyLabel.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            emptyLabel.topAnchor.constraint(equalTo: bgView.topAnchor, constant: Self.inputHeight),
            emptyLabel.heightAnchor.constraint(equalToConstant: ListItemView.itemHeight),
        ])

        // Add list view if in list mode
        if let state = state {
            let lv = ListView(state: state)
            lv.translatesAutoresizingMaskIntoConstraints = false
            bgView.addSubview(lv)
            self.listView = lv

            let listHeight = lv.requiredHeight
            let heightConstraint = lv.heightAnchor.constraint(equalToConstant: listHeight)
            self.listViewHeightConstraint = heightConstraint

            NSLayoutConstraint.activate([
                lv.leadingAnchor.constraint(equalTo: bgView.leadingAnchor),
                lv.trailingAnchor.constraint(equalTo: bgView.trailingAnchor),
                lv.topAnchor.constraint(equalTo: bgView.topAnchor, constant: Self.inputHeight),
                heightConstraint,
            ])

            lv.refresh()
        }
    }

    private func setupActions() {
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        textField.delegate = self
    }

    private func setupStateObserver() {
        state?.onStateChange = { [weak self] in
            self?.handleStateChange()
        }
    }

    private func handleStateChange() {
        listView?.refresh()
        updateWindowSize()
        updateEmptyLabel()
    }

    private func updateWindowSize() {
        // Update list view height constraint for content layout
        // Window size stays fixed - no frame changes (prevents shifting on filter)
        if let listView = listView {
            listViewHeightConstraint?.constant = listView.requiredHeight
        }

        // Redraw background
        contentView?.needsDisplay = true
    }

    private func updateEmptyLabel() {
        guard let state = state else {
            emptyLabel.isHidden = true
            return
        }
        emptyLabel.isHidden = !(state.hasItems && state.filteredResults.isEmpty)
    }

    @objc private func closeClicked() {
        finish(.cancelled)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // ESC - cancel
        if event.keyCode == 53 {
            finish(.cancelled)
            return
        }

        // Only handle navigation keys in list mode
        guard let state = state, state.isListMode else {
            super.keyDown(with: event)
            return
        }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Down arrow, j, or Ctrl-n
        if keyCode == 125 || (keyCode == 38 && modifiers.isEmpty) || (keyCode == 45 && modifiers == .control) {
            state.moveSelection(1)
            return
        }

        // Up arrow, k, or Ctrl-p
        if keyCode == 126 || (keyCode == 40 && modifiers.isEmpty) || (keyCode == 35 && modifiers == .control) {
            state.moveSelection(-1)
            return
        }

        super.keyDown(with: event)
    }

    func submit() {
        if let state = state, state.isListMode {
            if let selectedItem = state.selectedItem {
                finish(.selected(selectedItem))
            } else {
                // No selection available (empty list)
                finish(.cancelled)
            }
        } else {
            finish(.submitted(textField.stringValue))
        }
    }

    func focusInput() {
        makeFirstResponder(textField)
    }

    /// Recenter the window on the screen where the mouse cursor is
    func recenterOnMouseScreen() {
        guard let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let winSize = frame.size
        let screenFrame = targetScreen.frame
        setFrameOrigin(NSPoint(
            x: screenFrame.midX - winSize.width / 2,
            y: screenFrame.midY - winSize.height / 2
        ))
    }

    /// Reset the window for a new picker request (daemon mode)
    func resetForNewRequest(items: [PickerItem]) {
        textField.stringValue = ""
        state?.resetWithItems(items)
        recenterOnMouseScreen()
    }
}

extension PickerWindow: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            finish(.cancelled)
            return true
        }

        // Handle navigation in text field context
        if let state = state, state.isListMode {
            if commandSelector == #selector(moveDown(_:)) {
                state.moveSelection(1)
                return true
            }
            if commandSelector == #selector(moveUp(_:)) {
                state.moveSelection(-1)
                return true
            }
        }

        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        state?.updateQuery(textField.stringValue)
    }
}

// MARK: - NSLabel (simple label helper)

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

// MARK: - Background View

class BackgroundView: NSView {
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

        Colors.background.setFill()
        path.fill()

        Colors.border.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - Socket Listener (Daemon Mode)

/// Simplified socket server for picker daemon — accepts one request at a time
class SocketListener {
    private let socketPath: String
    private var serverSocket: Int32?

    /// Called on main thread with parsed items and the client connection fd
    var onRequest: (([PickerItem], Int32) -> Void)?

    init(path: String) {
        self.socketPath = path
    }

    func start() throws {
        // Clean up stale socket if needed
        if FileManager.default.fileExists(atPath: socketPath) {
            let testSock = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = makeSockAddr(socketPath)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    connect(testSock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            close(testSock)

            if connected == 0 {
                // Another daemon is listening
                throw PickerDaemonError.alreadyRunning
            }

            // Socket file exists but nobody is listening — stale, remove it
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw PickerDaemonError.socketFailed("socket(): \(String(cString: strerror(errno)))")
        }
        serverSocket = sock

        var addr = makeSockAddr(socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult >= 0 else {
            close(sock)
            serverSocket = nil
            throw PickerDaemonError.socketFailed("bind(): \(String(cString: strerror(errno)))")
        }

        guard listen(sock, 5) >= 0 else {
            close(sock)
            serverSocket = nil
            throw PickerDaemonError.socketFailed("listen(): \(String(cString: strerror(errno)))")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        guard let sock = serverSocket else { return }

        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(sock, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                break
            }

            // Read newline-delimited JSON request
            var buffer = Data()
            let readSize = 65536
            var foundNewline = false

            while !foundNewline {
                var chunk = [UInt8](repeating: 0, count: readSize)
                let bytesRead = recv(clientSocket, &chunk, readSize, 0)

                if bytesRead <= 0 {
                    break
                }

                buffer.append(contentsOf: chunk[0..<bytesRead])

                if buffer.contains(UInt8(ascii: "\n")) {
                    foundNewline = true
                }
            }

            guard foundNewline,
                  let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                close(clientSocket)
                continue
            }

            let messageData = buffer[buffer.startIndex..<newlineIndex]
            guard let items = try? JSONDecoder().decode([PickerItem].self, from: messageData) else {
                close(clientSocket)
                continue
            }

            DispatchQueue.main.async { [weak self] in
                self?.onRequest?(items, clientSocket)
            }
        }
    }

    func sendResponse(_ result: PickerResult, to connection: Int32) {
        let responseData = (result.json + "\n").data(using: .utf8) ?? Data()
        _ = responseData.withUnsafeBytes { ptr in
            send(connection, ptr.baseAddress, responseData.count, 0)
        }
        close(connection)
    }

    func stop() {
        if let sock = serverSocket {
            close(sock)
            serverSocket = nil
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func makeSockAddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { pathPtr in
                strcpy(ptr, pathPtr)
            }
        }
        return addr
    }
}

enum PickerDaemonError: Error {
    case alreadyRunning
    case socketFailed(String)
}

// MARK: - PID File Management

func checkExistingDaemon() -> Bool {
    guard let pidString = try? String(contentsOfFile: pickerPIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = Int32(pidString) else {
        return false
    }
    return kill(pid, 0) == 0
}

func writePIDFile() {
    try? String(getpid()).write(toFile: pickerPIDPath, atomically: true, encoding: .utf8)
}

func cleanupDaemonFiles() {
    try? FileManager.default.removeItem(atPath: pickerPIDPath)
    try? FileManager.default.removeItem(atPath: pickerSocketPath)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PickerWindow?
    var config: PickerConfig
    var socketListener: SocketListener?
    var activeConnection: Int32?
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?

    init(config: PickerConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isDaemonMode {
            NSApp.setActivationPolicy(.accessory)

            socketListener = SocketListener(path: pickerSocketPath)
            socketListener?.onRequest = { [weak self] items, conn in
                self?.handlePickerRequest(items: items, connection: conn)
            }

            do {
                try socketListener?.start()
            } catch PickerDaemonError.alreadyRunning {
                fputs("grid-picker daemon already running\n", stderr)
                exit(0)
            } catch {
                fputs("Failed to start picker socket: \(error)\n", stderr)
                exit(1)
            }

            writePIDFile()
            setupSignalHandlers()
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            window = PickerWindow(config: config)
            window?.makeKeyAndOrderFront(nil)
            window?.focusInput()
            observeWindowFocus()
        }
    }

    func handlePickerRequest(items: [PickerItem], connection: Int32) {
        // Cancel any existing in-flight request
        if let existingConn = activeConnection {
            socketListener?.sendResponse(.cancelled, to: existingConn)
        }
        activeConnection = connection

        if let window = window {
            window.resetForNewRequest(items: items)
        } else {
            var requestConfig = config
            requestConfig.items = items
            window = PickerWindow(config: requestConfig)
            observeWindowFocus()
        }

        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.focusInput()
    }

    private func observeWindowFocus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        finish(.cancelled)
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketListener?.stop()
        cleanupDaemonFiles()
    }

    private func setupSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTermSource?.setEventHandler {
            cleanupDaemonFiles()
            exit(0)
        }
        sigTermSource?.resume()

        sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource?.setEventHandler {
            cleanupDaemonFiles()
            exit(0)
        }
        sigIntSource?.resume()
    }
}

// MARK: - Stdin Parsing

/// Read items from stdin if available (non-blocking check)
func readItemsFromStdin() -> [PickerItem] {
    // Check if stdin has data (is not a tty)
    guard isatty(STDIN_FILENO) == 0 else {
        return []
    }

    // Read all stdin data
    var stdinData = Data()
    while let byte = try? FileHandle.standardInput.read(upToCount: 4096), !byte.isEmpty {
        stdinData.append(byte)
    }

    guard !stdinData.isEmpty else {
        return []
    }

    // Parse as JSON array of PickerItem
    do {
        let items = try JSONDecoder().decode([PickerItem].self, from: stdinData)
        return items
    } catch {
        fputs("Warning: Failed to parse stdin as [PickerItem]: \(error.localizedDescription)\n", stderr)
        return []
    }
}

// MARK: - Main

// Read stdin BEFORE starting NSApplication (blocking call)
let stdinItems = readItemsFromStdin()

// Detect mode: stdin with data = one-shot, otherwise = daemon
if isatty(STDIN_FILENO) == 0 && !stdinItems.isEmpty {
    isDaemonMode = false
} else {
    isDaemonMode = true

    if checkExistingDaemon() {
        fputs("grid-picker daemon already running\n", stderr)
        exit(0)
    }
}

var config = PickerConfig.parse(CommandLine.arguments)
config.items = stdinItems

// Test mode: run fuzzy matcher and output results as JSON
if let query = config.testQuery {
    let results = FuzzyMatcher.match(query: query, items: config.items)

    struct TestResult: Encodable {
        let id: String
        let title: String
        let priority: Int
        let score: Int
    }

    let testResults = results.prefix(20).map { result in
        TestResult(
            id: result.item.id,
            title: result.item.title,
            priority: result.item.priority,
            score: result.score
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(testResults),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
