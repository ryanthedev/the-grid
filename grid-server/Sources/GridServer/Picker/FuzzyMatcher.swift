//
// FuzzyMatcher.swift
// GridServer
//
// Fuzzy matching for picker items — ported from GridPicker/main.swift
//

import Foundation

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

    /// Characters treated as interchangeable separators
    private static let separators: Set<Character> = [".", "-", "_", " "]

    private static func isSeparator(_ c: Character) -> Bool {
        separators.contains(c)
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
                    text: text
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
    /// Always case-insensitive; exact case matches get a scoring bonus.
    /// Separators (. - _ space) are interchangeable and skippable in text.
    /// - Returns: (score, matched indices into original text) or nil if no match
    private static func matchSingle(
        query: String,
        text: String
    ) -> (Int, [Int])? {
        let queryChars = Array(query)
        let textChars = Array(text)
        let lowerTextChars = Array(text.lowercased())

        var queryIndex = 0
        var matchedIndices: [Int] = []
        var score = 0

        // Track consecutive matches for bonus
        var consecutiveCount = 0
        var lastMatchIndex = -2

        for textIndex in 0..<textChars.count {
            guard queryIndex < queryChars.count else { break }

            let qChar = queryChars[queryIndex]

            // Separator in query matches any separator in text
            if isSeparator(qChar) {
                if isSeparator(textChars[textIndex]) {
                    matchedIndices.append(textIndex)
                    score += 5
                    lastMatchIndex = textIndex
                    consecutiveCount = 0
                    queryIndex += 1
                }
                continue
            }

            // Case-insensitive comparison
            let lowerQ = Character(qChar.lowercased())
            if lowerTextChars[textIndex] == lowerQ {
                matchedIndices.append(textIndex)

                // Base score for a match
                var matchScore = 10

                // Bonus for exact case match
                if textChars[textIndex] == qChar {
                    matchScore += 3
                }

                // Bonus for consecutive matches
                if textIndex == lastMatchIndex + 1 {
                    consecutiveCount += 1
                    matchScore += consecutiveCount * 5
                } else {
                    consecutiveCount = 0
                }

                // Bonus for word boundary match (after separator or start)
                if textIndex == 0 || !textChars[textIndex - 1].isLetter {
                    matchScore += 15
                }

                // Bonus for camelCase match
                if textIndex > 0 && textChars[textIndex].isUppercase &&
                   textChars[textIndex - 1].isLowercase {
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

        // Bonus for exact match (case-insensitive)
        if text.lowercased() == query.lowercased() {
            score += 500
        }

        // Bonus for prefix match (case-insensitive)
        if text.lowercased().hasPrefix(query.lowercased()) {
            score += 200
        }

        return (score, matchedIndices)
    }
}
