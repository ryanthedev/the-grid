//
// FuzzyMatcher.swift
// GridServer
//
// Fuzzy matching algorithm for the picker
//

import Foundation

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
