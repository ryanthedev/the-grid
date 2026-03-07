# Phase 1 Pseudocode: Picker UI in Server + Window Source

Target directory: `grid-server/Sources/GridServer/Picker/`

All files compile within the GridServer target. No new SPM target needed.

---

## 1. PickerModels.swift

```
// Port PickerItem struct exactly from GridPicker/main.swift lines 40-144
// Keep: Codable, Equatable, id/title/subtitle/preview/icon/searchable/metadata/priority
// Keep: allSearchableText computed property
// Keep: backwards-compat Codable init (display fallback)
// Keep: CodingKeys enum

struct PickerItem: Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let preview: String?
    let icon: String?
    let searchable: [String]
    let metadata: [String: String]?
    let priority: Int

    var display: String { title }

    // memberwise init with defaults (subtitle/preview/icon = nil, searchable = [title], metadata = nil, priority = 0)
    // Decodable init: prefer "title", fallback to "display" key
    // Encodable: include both "title" and "display" for back-compat
    // allSearchableText: [title] + searchable + subtitle + preview (when non-nil)

    // EXACT PORT — copy lines 40-144 verbatim from GridPicker/main.swift
}

// Port MatchResult exactly from GridPicker/main.swift lines 390-400
struct MatchResult {
    let item: PickerItem
    let score: Int
    let matchedIndices: [Int]
}

// NEW: Action enum for what to do when an item is selected
enum PickerAction {
    case focusWindow(pid: pid_t, windowID: UInt32)
    case openApp(bundleID: String)
    // Future phases will add more cases

    // Parse from PickerItem.metadata dictionary
    // Convention: metadata["action"] = "focusWindow", metadata["pid"] = "123", metadata["windowID"] = "456"
    static func from(metadata: [String: String]?) -> PickerAction? {
        guard let meta = metadata, let action = meta["action"] else { return nil }
        switch action {
        case "focusWindow":
            guard let pidStr = meta["pid"], let pid = Int32(pidStr),
                  let widStr = meta["windowID"], let wid = UInt32(widStr) else { return nil }
            return .focusWindow(pid: pid, windowID: wid)
        case "openApp":
            guard let bundleID = meta["bundleID"] else { return nil }
            return .openApp(bundleID: bundleID)
        default:
            return nil
        }
    }
}

// Simplified result enum (no JSON output, no exit codes — server handles actions directly)
enum PickerResult {
    case selected(PickerItem)
    case cancelled
}
```

---

## 2. FuzzyMatcher.swift

```
// EXACT PORT of FuzzyMatcher enum from GridPicker/main.swift lines 403-598
// No modifications needed — it references PickerItem and MatchResult which are in PickerModels.swift

enum FuzzyMatcher {

    private enum FieldType {
        case title, subtitle, preview, searchable
        var weight: Double { ... }  // title/searchable=1.0, subtitle=0.7, preview=0.5
    }

    // match(query:items:) -> [MatchResult]
    //   - empty query returns all items with score=0
    //   - smart case: case-insensitive unless query contains uppercase
    //   - for each item, score against all fields (title, subtitle, preview, searchable)
    //   - apply field weight to raw score
    //   - capture title match indices for highlighting
    //   - add priority bonus (priority / 3)
    //   - sort by score desc, then display asc

    // matchSingle(query:text:caseSensitive:) -> (Int, [Int])?
    //   - normalize separators (- and _ to space)
    //   - character-by-character fuzzy match
    //   - scoring: base=10, consecutive bonus=count*5, word boundary=+15, camelCase=+10, start=+20
    //   - penalty for later matches: -textIndex/5
    //   - bonus: shorter text (+max(0, 100-len)), exact match(+500), prefix match(+200)

    // EXACT PORT — copy lines 403-598 verbatim from GridPicker/main.swift
}
```

---

## 3. PickerState.swift

```
// Port PickerState class from GridPicker/main.swift lines 602-781
// ADD: appendItems() method for async streaming

class PickerState {
    private(set) var allItems: [PickerItem]
    private(set) var query: String = ""
    private(set) var filteredResults: [MatchResult] = []
    private(set) var selectedIndex: Int = 0
    private(set) var scrollOffset: Int = 0
    static let maxListHeight: CGFloat = 600
    var onStateChange: (() -> Void)?

    // init(items: [PickerItem])
    //   - store items, run initial filter with empty query

    // updateQuery(_ newQuery: String)
    //   - set query, re-run FuzzyMatcher.match, reset selectedIndex and scrollOffset to 0
    //   - fire onStateChange

    // moveSelection(_ delta: Int)
    //   - clamp new index to [0, filteredResults.count-1]
    //   - adjust scrollOffset if selection goes above or below visible area
    //   - fire onStateChange

    // selectedItem: PickerItem? — filteredResults[selectedIndex].item if valid
    // selectedResult: MatchResult? — filteredResults[selectedIndex] if valid

    // visibleResults: [MatchResult]
    //   - accumulate items from scrollOffset until maxListHeight exceeded
    //   - always include at least one item

    // hasItems: Bool — !allItems.isEmpty
    // isListMode: Bool — hasItems

    // resetWithItems(_ items: [PickerItem])
    //   - replace allItems, reset query/selectedIndex/scrollOffset, re-filter, fire onStateChange

    // EXACT PORT of all above from lines 602-781

    // ---- NEW METHOD ----

    /// Append new items from an async source, deduplicating by ID
    /// Must be called on main thread
    func appendItems(_ newItems: [PickerItem]) {
        // Build a Set of existing item IDs for O(1) lookup
        let existingIDs = Set(allItems.map { $0.id })

        // Filter out duplicates
        let unique = newItems.filter { !existingIDs.contains($0.id) }
        guard !unique.isEmpty else { return }

        // Append to allItems
        allItems.append(contentsOf: unique)

        // Preserve current selection identity (not just index)
        let previouslySelectedID = selectedItem?.id

        // Re-filter against current query
        filteredResults = FuzzyMatcher.match(query: query, items: allItems)

        // Restore selection by ID if it still exists in filtered results
        if let prevID = previouslySelectedID,
           let restoredIndex = filteredResults.firstIndex(where: { $0.item.id == prevID }) {
            selectedIndex = restoredIndex
            // Adjust scroll to keep selection visible (reuse existing scroll logic)
            // If selection is before scrollOffset, pull scrollOffset back
            if selectedIndex < scrollOffset {
                scrollOffset = selectedIndex
            }
            // If selection is past visible area, use findScrollOffsetToShow
            let visibleCount = countVisibleItemsFrom(scrollOffset)
            if selectedIndex >= scrollOffset + visibleCount {
                scrollOffset = findScrollOffsetToShow(selectedIndex)
            }
        }
        // If previously selected item disappeared from results, keep selectedIndex clamped
        else {
            selectedIndex = min(selectedIndex, max(0, filteredResults.count - 1))
        }

        onStateChange?()
    }

    // Private helpers (ported exactly):
    // findScrollOffsetToShow(_ targetIndex: Int) -> Int
    // countVisibleItemsFrom(_ startIndex: Int) -> Int
}
```

---

## 4. PickerViews.swift

```
// Port visual components from GridPicker/main.swift with renames per discovery doc

// MARK: - Colors → PickerColors (lines 1198-1215)
struct PickerColors {
    static let background = NSColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 0.98)
    static let inputBackground = NSColor(red: 0.137, green: 0.137, blue: 0.137, alpha: 1)
    static let text = NSColor(red: 0.749, green: 0.749, blue: 0.749, alpha: 1)
    static let textSecondary = NSColor(red: 0.58, green: 0.58, blue: 0.58, alpha: 1)
    static let textTertiary = NSColor(red: 0.478, green: 0.478, blue: 0.478, alpha: 1)
    static let placeholder = NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
    static let border = NSColor(red: 0.251, green: 0.251, blue: 0.251, alpha: 1)
    static let prompt = NSColor(red: 0.0, green: 0.749, blue: 1.0, alpha: 1)
    // EXACT values from lines 1198-1215, just rename struct
}

// MARK: - Fonts → PickerFonts (lines 1219-1227)
enum PickerFonts {
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // Try BerkeleyMono Nerd Font, fallback to monospacedSystemFont
        // EXACT PORT from lines 1219-1227
    }
}

// MARK: - NSLabel (lines 1560-1572) — no rename needed
class NSLabel: NSTextField {
    // Non-editable, no border, no background, not selectable
    // EXACT PORT from lines 1560-1572
}

// MARK: - IconRenderer (lines 146-386) — no rename needed
class IconRenderer {
    // EXACT PORT from lines 146-386
    // Static cache, targetSize=24
    // render(_ iconString: String?) -> NSImage?
    // detectAndRender: bundle:, data:image/, <svg, file path, emoji
    // loadFromBundle, renderDataURL, renderSVG, loadFromFile, renderEmoji
    // scaleImage, isFilePath, isLikelyEmoji, clearCache
    //
    // ALL references to Colors. become PickerColors.
    // ALL references to Fonts. become PickerFonts.
    // (IconRenderer itself doesn't reference Colors/Fonts, but note for consistency)
}

// MARK: - BackgroundView → PickerBackgroundView (lines 1576-1601)
class PickerBackgroundView: NSView {
    // wantsLayer = true
    // draw: rounded rect with PickerColors.background fill, PickerColors.border stroke
    // acceptsFirstMouse returns true
    // EXACT PORT from lines 1576-1601, rename Colors→PickerColors
}

// MARK: - ListItemView (lines 785-948) — no rename needed
class ListItemView: NSView {
    // Card-based item row rendering
    // Layout constants: verticalPadding=12, titleLineHeight=24, subtitleLineHeight=20,
    //   previewLineHeight=18, iconColumnWidth=48, horizontalPadding=16
    // Card styling: cardCornerRadius=6, cardInset=8, itemGap=6
    // Static itemHeight=48, heightForItem(_ item:) calculates variable height
    //
    // draw(): card bg, icon on RIGHT, title with match highlighting, subtitle, preview
    // buildTitleAttributedString(): highlight matchedIndices with PickerColors.prompt
    //
    // EXACT PORT from lines 785-948
    // ALL Colors. → PickerColors.
    // ALL Fonts. → PickerFonts.
}

// MARK: - ListView → PickerListView (lines 952-1026)
class PickerListView: NSView {
    private weak var state: PickerState?
    private var itemViews: [ListItemView] = []

    // init(state:) — wantsLayer = true
    // hasAnyIcons: Bool — check if any filtered result has icon
    // refresh(): remove old views, create ListItemView for each visible result,
    //   position with cumulative Y offset, Auto Layout constraints
    // requiredHeight: sum of visible item heights
    // shouldShowEmptyMessage: hasItems && filteredResults.isEmpty

    // EXACT PORT from lines 952-1026
    // Rename class only; internal refs to ListItemView stay the same
}
```

---

## 5. PickerWindow.swift

```
// Port PickerWindow from GridPicker/main.swift lines 1231-1556
// REMOVE: PickerConfig dependency (hardcode width=800, always list mode)
// ADD: spinner (NSProgressIndicator)
// ADD: recenterOnMouseScreen() — already exists in original, keep it
// CHANGE: finish() calls route to PickerManager instead of process exit

class PickerWindow: NSWindow, NSTextFieldDelegate {
    private let textField: NSTextField
    private let closeButton: NSButton
    private let emptyLabel: NSLabel
    private let spinner: NSProgressIndicator  // NEW

    // List mode components (always present — always list mode)
    private var state: PickerState
    private var listView: PickerListView
    private var listViewHeightConstraint: NSLayoutConstraint?

    // Layout constants
    private static let inputHeight: CGFloat = 68
    private static let listPadding: CGFloat = 8
    private static let windowWidth: CGFloat = 800

    // Callback for results (set by PickerManager)
    var onResult: ((PickerResult) -> Void)?

    init() {
        // Create text field (same as original: no border, no bg, focusRing=none, font=PickerFonts.mono(19))
        textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = PickerFonts.mono(size: 19)
        textField.textColor = PickerColors.text

        // NO prompt label (remove — picker always shows list, no static prompt)

        // Close button (same as original)
        closeButton = NSButton(title: "✕", target: nil, action: nil)
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = PickerColors.placeholder

        // Empty label (same as original)
        emptyLabel = NSLabel()
        emptyLabel.stringValue = "No matches"
        emptyLabel.font = PickerFonts.mono(size: 17)
        emptyLabel.textColor = PickerColors.placeholder
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // NEW: Spinner for loading state
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Always start with empty state (items appended async)
        state = PickerState(items: [])

        // Calculate initial window size — always full list height
        let initialHeight = Self.inputHeight + PickerState.maxListHeight + Self.listPadding

        // Center on mouse screen (use recenterOnMouseScreen logic inline for super.init)
        let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first!
        let origin = NSPoint(
            x: targetScreen.frame.midX - Self.windowWidth / 2,
            y: targetScreen.frame.midY - initialHeight / 2
        )

        // Create list view before super.init
        listView = PickerListView(state: state)

        super.init(
            contentRect: NSRect(origin: origin, size: CGSize(width: Self.windowWidth, height: initialHeight)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()       // level, collectionBehavior, transparency, shadow
        setupContentView()  // PickerBackgroundView as contentView
        setupLayout()       // constraints for textField, closeButton, emptyLabel, spinner, listView
        setupActions()      // closeButton target, textField delegate
        setupStateObserver() // state.onStateChange -> handleStateChange
    }

    // --- setupWindow() ---
    // EXACT same as original lines 1324-1333:
    // level = .floating
    // collectionBehavior = [.canJoinAllSpaces, .transient]
    // isOpaque = false, backgroundColor = .clear, hasShadow = true
    // titleVisibility = .hidden, titlebarAppearsTransparent = true
    // acceptsMouseMovedEvents = true

    // --- setupContentView() ---
    // contentView = PickerBackgroundView()

    // --- setupLayout() ---
    // Layout WITHOUT prompt label (prompt removed):
    //   textField: leading=padding, top=padding, height=inputHeight-2*padding, trailing→spinner.leading
    //   spinner: trailing→closeButton.leading-8, centerY=textField.centerY, width=16, height=16
    //   closeButton: trailing=-padding, top=padding, width=24, height=inputHeight-2*padding
    //   emptyLabel: below inputHeight, full width
    //   listView: below inputHeight, leading/trailing to bgView
    //     listViewHeightConstraint = listView.heightAnchor = requiredHeight

    // --- setupActions() ---
    // closeButton.action = closeClicked → onResult?(.cancelled)
    // textField.delegate = self

    // --- setupStateObserver() ---
    // state.onStateChange = { [weak self] in self?.handleStateChange() }

    // --- handleStateChange() ---
    // listView.refresh()
    // updateWindowSize()  // update listViewHeightConstraint, contentView.needsDisplay
    // updateEmptyLabel()  // show/hide based on state

    // --- Key handling ---
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // ESC (keyCode 53) → onResult?(.cancelled)
        // Down arrow / Ctrl-n → state.moveSelection(1)
        // Up arrow / Ctrl-p → state.moveSelection(-1)
        // (Remove j/k navigation — conflicts with typing in search field)
        // else: super.keyDown(with: event)
    }

    // --- NSTextFieldDelegate ---
    func control(_:textView:doCommandBy:) -> Bool {
        // insertNewline → submit()
        // cancelOperation → onResult?(.cancelled)
        // moveDown → state.moveSelection(1)
        // moveUp → state.moveSelection(-1)
    }

    func controlTextDidChange(_:) {
        state.updateQuery(textField.stringValue)
    }

    // --- submit() ---
    func submit() {
        if let selectedItem = state.selectedItem {
            onResult?(.selected(selectedItem))
        } else {
            onResult?(.cancelled)
        }
    }

    // --- Public API for PickerManager ---

    func focusInput() {
        makeFirstResponder(textField)
    }

    func recenterOnMouseScreen() {
        // EXACT PORT from lines 1506-1517
        // Find screen containing mouse, center window on it
    }

    /// Reset for a new show cycle
    func resetForNewShow() {
        textField.stringValue = ""
        state.resetWithItems([])  // start empty, items arrive via appendItems
        recenterOnMouseScreen()
    }

    /// Expose state for PickerManager to call appendItems
    func getState() -> PickerState {
        return state
    }

    /// Show/hide the loading spinner
    func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}
```

---

## 6. PickerManager.swift

```
// NEW file — singleton orchestrator for the picker lifecycle
// Follows SimpleBorderManager pattern: main-thread class, not actor

import AppKit

class PickerManager {
    static let shared = PickerManager()

    private var window: PickerWindow?
    private var discoveryTask: Task<Void, Never>?
    private var isVisible = false

    // Grace period to ignore windowDidResignKey during activation policy switch
    private var isActivating = false
    private var activationGraceTimer: DispatchWorkItem?

    private init() {}

    // --- show() ---
    // Called from BFDManager when @pick hotkey fires
    // Must be called on main thread
    func show() {
        dispatchPrecondition(condition: .onQueue(.main))

        // If already visible, treat as toggle → hide
        if isVisible {
            hide()
            return
        }

        isVisible = true

        // Create window lazily (reuse across show/hide cycles)
        if window == nil {
            window = PickerWindow()
            window!.onResult = { [weak self] result in
                self?.handleResult(result)
            }
            // Observe window resign key for auto-dismiss
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }

        // Reset window state for fresh show
        window!.resetForNewShow()
        window!.setLoading(true)

        // Set activation policy to .regular so we can receive key events
        // Set grace period flag to ignore resign-key during policy switch
        isActivating = true
        activationGraceTimer?.cancel()

        NSApp.setActivationPolicy(.regular)

        // Show and focus
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window!.focusInput()

        // End grace period after a short delay (200ms)
        let graceWork = DispatchWorkItem { [weak self] in
            self?.isActivating = false
        }
        activationGraceTimer = graceWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: graceWork)

        // Start async discovery
        discoveryTask = Task { [weak self] in
            await self?.discoverAndStream()
        }

        jlog("pick.show")
    }

    // --- hide() ---
    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard isVisible else { return }
        isVisible = false

        // Cancel in-flight discovery
        discoveryTask?.cancel()
        discoveryTask = nil

        // Hide window
        window?.orderOut(nil)
        window?.setLoading(false)

        // Switch back to prohibited (no dock icon)
        NSApp.setActivationPolicy(.prohibited)

        jlog("pick.hide")
    }

    // --- handleResult(_ result: PickerResult) ---
    // Called by PickerWindow.onResult callback
    private func handleResult(_ result: PickerResult) {
        // Hide first (clears UI before action)
        hide()

        switch result {
        case .selected(let item):
            executeAction(for: item)
        case .cancelled:
            break
        }
    }

    // --- executeAction(for item: PickerItem) ---
    private func executeAction(for item: PickerItem) {
        guard let action = PickerAction.from(metadata: item.metadata) else {
            jlog("pick.err.noaction", data: ["id": item.id])
            return
        }

        switch action {
        case .focusWindow(let pid, let windowID):
            // Create WindowManipulator and focus
            let connectionID = SLSMainConnectionID()
            let manipulator = WindowManipulator(connectionID: connectionID)
            let success = manipulator.focusWindow(pid: pid, windowID: windowID)
            jlog("pick.focus", data: [
                "pid": "\(pid)",
                "wid": "\(windowID)",
                "ok": "\(success)"
            ])

        case .openApp(let bundleID):
            // Open app via NSWorkspace
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error = error {
                        jlog("pick.err.open", data: ["bundle": bundleID, "err": "\(error)"])
                    }
                }
            }
        }
    }

    // --- discoverAndStream() ---
    // Runs all PickerSources in a TaskGroup, appends items as each completes
    private func discoverAndStream() async {
        let sources: [PickerSource] = [
            WindowSource()
            // Future phases: AppSource(), ZoxideSource(), etc.
        ]

        await withTaskGroup(of: [PickerItem].self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return try await source.discover()
                    } catch {
                        // Log error, return empty
                        jlog("pick.err.source", data: ["source": source.id, "err": "\(error)"])
                        return []
                    }
                }
            }

            for await items in group {
                // Check cancellation before dispatching to main
                guard !Task.isCancelled else { break }

                // Append items on main thread
                await MainActor.run {
                    guard isVisible, let window = window else { return }
                    window.getState().appendItems(items)
                }
            }
        }

        // All sources complete — hide spinner on main thread
        await MainActor.run {
            window?.setLoading(false)
        }
    }

    // --- windowDidResignKey ---
    @objc private func windowDidResignKey(_ notification: Notification) {
        // Skip during activation grace period (policy switch causes transient resign)
        guard !isActivating else { return }
        handleResult(.cancelled)
    }
}
```

---

## 7. PickerSource.swift

```
// Simple protocol for picker data sources

protocol PickerSource {
    /// Unique identifier for this source (for logging)
    var id: String { get }

    /// Discover items from this source
    /// Called from a TaskGroup — may run concurrently with other sources
    func discover() async throws -> [PickerItem]
}
```

---

## 8. WindowSource.swift

```
// Reads windows from StateManager, builds PickerItems

struct WindowSource: PickerSource {
    let id = "windows"

    func discover() async throws -> [PickerItem] {
        let state = await StateManager.shared.getState()

        var items: [PickerItem] = []

        // Build a pid → ApplicationState lookup for bundleIdentifier
        // state.applications is [String: ApplicationState] keyed by pid string

        for (windowIDStr, window) in state.windows {
            // Skip hidden and minimized windows
            guard !window.isHidden, !window.isMinimized else { continue }

            // Skip windows with alpha near zero (invisible)
            guard window.alpha > 0.01 else { continue }

            // Skip non-standard windows (popups, menus, etc.)
            // Only include AXStandardWindow subrole, or nil subrole (some apps don't set it)
            if let subrole = window.subrole, subrole != "AXStandardWindow" {
                continue
            }

            // Look up application info
            let pidStr = "\(window.pid)"
            let app = state.applications[pidStr]
            let appName = window.appName ?? app?.localizedName ?? "Unknown"
            let bundleID = app?.bundleIdentifier

            // Build title: "AppName — Window Title" or just "AppName" if no title
            let title: String
            if let windowTitle = window.title, !windowTitle.isEmpty, windowTitle != appName {
                title = "\(appName) — \(windowTitle)"
            } else {
                title = appName
            }

            // Icon from bundle ID
            let icon: String? = bundleID.map { "bundle:\($0)" }

            // Searchable: app name + window title + bundle ID
            var searchable = [appName]
            if let windowTitle = window.title, !windowTitle.isEmpty {
                searchable.append(windowTitle)
            }
            if let bid = bundleID {
                searchable.append(bid)
            }

            // Metadata for action
            var metadata: [String: String] = [
                "action": "focusWindow",
                "pid": "\(window.pid)",
                "windowID": windowIDStr
            ]
            if let bid = bundleID {
                metadata["bundleID"] = bid
            }

            let item = PickerItem(
                id: "win-\(windowIDStr)",
                title: title,
                subtitle: bundleID,
                icon: icon,
                searchable: searchable,
                metadata: metadata,
                priority: 1000  // Windows get high priority
            )

            items.append(item)
        }

        // Sort by app name then window title for consistent ordering
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return items
    }
}
```

---

## 9. BFDManager.swift — Modification

```
// File: grid-server/Sources/GridServer/BFD/BFDManager.swift
// MODIFY: the onHotkeyTriggered callback in init()

// BEFORE (line 18-20):
//   keyHandler.onHotkeyTriggered = { [weak self] spec, def in
//       self?.executor?.executeAsync(hotkey: spec, command: def.run)
//   }

// AFTER:
keyHandler.onHotkeyTriggered = { [weak self] spec, def in
    let command = def.run.trimmingCharacters(in: .whitespaces)

    // Check for @ commands (internal server actions, skip BFDExecutor)
    if command.hasPrefix("@") {
        self?.handleInternalCommand(command, hotkey: spec)
        return
    }

    self?.executor?.executeAsync(hotkey: spec, command: def.run)
}

// ADD new private method to BFDManager:
private func handleInternalCommand(_ command: String, hotkey: String) {
    switch command {
    case "@pick":
        DispatchQueue.main.async {
            PickerManager.shared.show()
        }
        JSONLogger.shared.log("bfd.internal", data: ["cmd": command, "hotkey": hotkey])

    default:
        JSONLogger.shared.log("bfd.err.internal", data: [
            "cmd": command,
            "msg": "unknown @ command"
        ])
    }
}
```

---

## File Summary

| File | Action | Location |
|------|--------|----------|
| `PickerModels.swift` | NEW | `Picker/PickerModels.swift` |
| `FuzzyMatcher.swift` | NEW | `Picker/FuzzyMatcher.swift` |
| `PickerState.swift` | NEW | `Picker/PickerState.swift` |
| `PickerViews.swift` | NEW | `Picker/PickerViews.swift` |
| `PickerWindow.swift` | NEW | `Picker/PickerWindow.swift` |
| `PickerManager.swift` | NEW | `Picker/PickerManager.swift` |
| `PickerSource.swift` | NEW | `Picker/PickerSource.swift` |
| `WindowSource.swift` | NEW | `Picker/WindowSource.swift` |
| `BFDManager.swift` | MODIFY | `BFD/BFDManager.swift` |

## BFD Config Change

To wire the hotkey, add to `~/.config/thegrid/bfd.yaml`:

```yaml
hotkeys:
  ctrl-space: "@pick"
```

No server restart needed if config watcher is active — BFDManager will reload automatically.

## Testing Checklist

1. `ctrl-space` opens picker window centered on mouse screen
2. Window shows spinner while loading
3. Windows from StateManager appear as items with app icons
4. Typing filters items with fuzzy matching and match highlighting
5. Up/Down arrow navigates selection
6. Enter focuses the selected window (picker hides first)
7. ESC or focus loss hides picker and restores `.prohibited` policy
8. Rapid toggle (ctrl-space twice) shows then hides cleanly
9. No dock icon when picker is hidden
