//
// PickerState.swift
// GridServer
//
// Observable state for the picker UI — ported from GridPicker/main.swift
// Adds appendItems() for async streaming sources
//

import Foundation

/// Observable state for the picker UI
class PickerState {
    /// All items (may grow as async sources deliver results)
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

    /// Reset state with new items (for reuse across show/hide cycles)
    func resetWithItems(_ items: [PickerItem]) {
        allItems = items
        query = ""
        filteredResults = FuzzyMatcher.match(query: "", items: items)
        selectedIndex = 0
        scrollOffset = 0
        onStateChange?()
    }

    // MARK: - Async Streaming

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
            // If selection is before scrollOffset, pull scrollOffset back
            if selectedIndex < scrollOffset {
                scrollOffset = selectedIndex
            }
            // If selection is past visible area, adjust scroll
            let visibleCount = countVisibleItemsFrom(scrollOffset)
            if selectedIndex >= scrollOffset + visibleCount {
                scrollOffset = findScrollOffsetToShow(selectedIndex)
            }
        } else {
            // If previously selected item disappeared from results, keep selectedIndex clamped
            selectedIndex = min(selectedIndex, max(0, filteredResults.count - 1))
        }

        onStateChange?()
    }
}
