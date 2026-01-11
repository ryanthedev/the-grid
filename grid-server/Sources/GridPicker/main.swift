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

// MARK: - Data Models

/// A single item that can be displayed and selected in the picker
struct PickerItem: Codable, Equatable {
    /// Unique identifier for this item
    let id: String

    /// Display text shown in the picker
    let display: String

    /// Additional strings to search against (e.g., description, path, tags)
    let searchable: [String]

    /// Optional metadata passed back on selection (picker ignores this)
    let metadata: [String: String]?

    init(id: String, display: String, searchable: [String]? = nil, metadata: [String]? = nil) {
        self.id = id
        self.display = display
        self.searchable = searchable ?? [display]
        self.metadata = nil
    }

    init(id: String, display: String, searchable: [String]? = nil, metadata: [String: String]?) {
        self.id = id
        self.display = display
        self.searchable = searchable ?? [display]
        self.metadata = metadata
    }

    /// Custom Decodable init to handle optional searchable field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        display = try container.decode(String.self, forKey: .display)
        let optionalSearchable = try container.decodeIfPresent([String].self, forKey: .searchable)
        searchable = optionalSearchable ?? [display]
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case id, display, searchable, metadata
    }

    /// Get all searchable text (display + searchable fields)
    var allSearchableText: [String] {
        [display] + searchable
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
            // Try to match against all searchable fields, take best score
            var bestScore = Int.min
            var bestIndices: [Int] = []

            for searchText in item.allSearchableText {
                if let (score, indices) = matchSingle(
                    query: query,
                    text: searchText,
                    caseSensitive: caseSensitive,
                    isDisplayField: searchText == item.display
                ) {
                    if score > bestScore {
                        bestScore = score
                        // Only keep indices if this is the display field
                        bestIndices = searchText == item.display ? indices : []
                    }
                }
            }

            if bestScore > Int.min {
                results.append(MatchResult(item: item, score: bestScore, matchedIndices: bestIndices))
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
    ///   - isDisplayField: Whether this is the display field (affects scoring)
    /// - Returns: (score, matched indices) or nil if no match
    private static func matchSingle(
        query: String,
        text: String,
        caseSensitive: Bool,
        isDisplayField: Bool
    ) -> (Int, [Int])? {
        let queryChars = caseSensitive ? Array(query) : Array(query.lowercased())
        let textChars = caseSensitive ? Array(text) : Array(text.lowercased())
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

        // Bonus for display field matches
        if isDisplayField {
            score += 50
        }

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

    /// Maximum visible items in the list
    let maxVisibleItems: Int = 10

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
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + maxVisibleItems {
            scrollOffset = selectedIndex - maxVisibleItems + 1
        }

        onStateChange?()
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

    /// Get visible results based on scroll offset
    var visibleResults: ArraySlice<MatchResult> {
        let start = scrollOffset
        let end = min(scrollOffset + maxVisibleItems, filteredResults.count)
        guard start < end else { return [] }
        return filteredResults[start..<end]
    }

    /// Check if there are items to display
    var hasItems: Bool {
        !allItems.isEmpty
    }

    /// Check if we're in list mode (have items) vs simple input mode
    var isListMode: Bool {
        hasItems
    }
}

// MARK: - List Item View

/// A single row in the picker list
class ListItemView: NSView {
    private let displayText: String
    private let matchedIndices: Set<Int>
    private let isSelected: Bool

    static let itemHeight: CGFloat = 28

    init(displayText: String, matchedIndices: [Int], isSelected: Bool) {
        self.displayText = displayText
        self.matchedIndices = Set(matchedIndices)
        self.isSelected = isSelected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds

        // Draw selection background
        if isSelected {
            Colors.inputBackground.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 4, yRadius: 4).fill()
        }

        // Build attributed string with highlighting
        let attributedString = NSMutableAttributedString(
            string: displayText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: Colors.text
            ]
        )

        // Highlight matched characters
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
                attributedString.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), range: range)
            }
        }

        // Draw text
        let textRect = bounds.insetBy(dx: 12, dy: 0)
        let textHeight = attributedString.size().height
        let yOffset = (bounds.height - textHeight) / 2
        attributedString.draw(in: NSRect(x: textRect.minX, y: yOffset, width: textRect.width, height: textHeight))
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

    /// Refresh the list view based on current state
    func refresh() {
        // Remove old views
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        guard let state = state else { return }

        let visibleResults = Array(state.visibleResults)

        for (viewIndex, result) in visibleResults.enumerated() {
            let actualIndex = state.scrollOffset + viewIndex
            let isSelected = actualIndex == state.selectedIndex

            let itemView = ListItemView(
                displayText: result.item.display,
                matchedIndices: result.matchedIndices,
                isSelected: isSelected
            )
            itemView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(itemView)
            itemViews.append(itemView)

            NSLayoutConstraint.activate([
                itemView.leadingAnchor.constraint(equalTo: leadingAnchor),
                itemView.trailingAnchor.constraint(equalTo: trailingAnchor),
                itemView.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(viewIndex) * ListItemView.itemHeight),
                itemView.heightAnchor.constraint(equalToConstant: ListItemView.itemHeight)
            ])
        }
    }

    /// Calculate required height based on visible item count
    var requiredHeight: CGFloat {
        guard let state = state else { return 0 }
        let visibleCount = min(state.filteredResults.count, state.maxVisibleItems)
        return CGFloat(visibleCount) * ListItemView.itemHeight
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
    var width: CGFloat = 400
    var height: CGFloat = 56
    var items: [PickerItem] = []

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
            "display": item.display,
            "searchable": item.searchable
        ]
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
        return "{\"cancelled\": false, \"selected\": {\"id\": \"\(escapeJSON(item.id))\", \"display\": \"\(escaped)\"}}"
    }
}

func finish(_ result: PickerResult) -> Never {
    print(result.json)
    exit(result.exitCode)
}

// MARK: - Colors (Catppuccin Mocha)

struct Colors {
    static let background = NSColor(red: 0.118, green: 0.118, blue: 0.180, alpha: 0.95)
    static let inputBackground = NSColor(red: 0.192, green: 0.200, blue: 0.267, alpha: 1)
    static let text = NSColor(red: 0.804, green: 0.839, blue: 0.957, alpha: 1)
    static let placeholder = NSColor(red: 0.424, green: 0.439, blue: 0.525, alpha: 1)
    static let border = NSColor(red: 0.345, green: 0.357, blue: 0.439, alpha: 1)
    static let prompt = NSColor(red: 0.537, green: 0.706, blue: 0.980, alpha: 1)
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
    private var windowHeightConstraint: NSLayoutConstraint?

    // Layout constants
    private static let inputHeight: CGFloat = 56
    private static let listPadding: CGFloat = 8

    init(config: PickerConfig) {
        self.config = config

        // Create text field
        textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textField.textColor = Colors.text
        textField.placeholderString = "Type to filter..."
        textField.placeholderAttributedString = NSAttributedString(
            string: config.items.isEmpty ? "Type here..." : "Type to filter...",
            attributes: [
                .foregroundColor: Colors.placeholder,
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            ]
        )

        // Create prompt label
        promptLabel = NSLabel()
        promptLabel.stringValue = config.prompt
        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
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
        emptyLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
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
        let initialHeight: CGFloat
        if let st = pickerState, st.hasItems {
            let listHeight = CGFloat(min(st.filteredResults.count, st.maxVisibleItems)) * ListItemView.itemHeight
            if listHeight == 0 {
                initialHeight = Self.inputHeight + ListItemView.itemHeight + Self.listPadding
            } else {
                initialHeight = Self.inputHeight + listHeight + Self.listPadding
            }
        } else {
            initialHeight = Self.inputHeight
        }

        // Calculate position - center on screen
        let screen = NSScreen.main ?? NSScreen.screens.first!
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

    private func calculateWindowHeight() -> CGFloat {
        guard let state = state, state.hasItems else {
            return Self.inputHeight
        }
        let listHeight = CGFloat(min(state.filteredResults.count, state.maxVisibleItems)) * ListItemView.itemHeight
        if listHeight == 0 {
            // Show "No matches" row
            return Self.inputHeight + ListItemView.itemHeight + Self.listPadding
        }
        return Self.inputHeight + listHeight + Self.listPadding
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
        let newHeight = calculateWindowHeight()
        guard abs(frame.height - newHeight) > 1 else { return }

        // Update list view height
        if let listView = listView {
            listViewHeightConstraint?.constant = listView.requiredHeight
        }

        // Keep window centered while resizing
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let newOrigin = NSPoint(
            x: screen.frame.midX - config.width / 2,
            y: screen.frame.midY - newHeight / 2
        )

        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: config.width, height: newHeight))
        setFrame(newFrame, display: true, animate: false)

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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)

        Colors.background.setFill()
        path.fill()

        Colors.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PickerWindow?
    let config: PickerConfig

    init(config: PickerConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window = PickerWindow(config: config)
        window?.makeKeyAndOrderFront(nil)
        window?.focusInput()

        // Watch for focus loss
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

var config = PickerConfig.parse(CommandLine.arguments)
config.items = stdinItems

let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
