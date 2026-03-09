//
// PickerHistory.swift
// GridServer
//
// Tracks picker selection frequency and recency (frecency).
// Persists to ~/.local/state/thegrid/picker-history.json.
// Loaded once on server start, saved on each selection.
//

import Foundation

class PickerHistory {
    static let maxEntries = 100
    static let historyVersion = 1

    // File path: ~/.local/state/thegrid/picker-history.json
    private let filePath: String

    // Schema fields
    var version: Int = PickerHistory.historyVersion
    var previous: String = ""
    var frequency: [String: Int] = [:]
    var lastPicked: [String: Int64] = [:]  // unix timestamps

    // MARK: - Init / Load

    init() {
        filePath = thegridStateDir + "/picker-history.json"
    }

    /// Load from disk. Returns fresh history if file missing or corrupt.
    static func load() -> PickerHistory {
        let history = PickerHistory()

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: history.filePath)) else {
            // No file = fresh history (normal on first run)
            return history
        }

        // Decode JSON
        struct HistoryFile: Codable {
            var version: Int
            var previous: String
            var frequency: [String: Int]
            var lastPicked: [String: Int64]
        }

        guard let decoded = try? JSONDecoder().decode(HistoryFile.self, from: data) else {
            jlog("pick.hist.parse_err")
            return history
        }

        // Validate: no negative frequencies or timestamps
        for (id, freq) in decoded.frequency {
            guard freq >= 0 else {
                jlog("pick.hist.invalid", data: ["id": id, "freq": "\(freq)"])
                return history
            }
        }
        for (id, ts) in decoded.lastPicked {
            guard ts >= 0 else {
                jlog("pick.hist.invalid", data: ["id": id, "ts": "\(ts)"])
                return history
            }
        }

        history.version = decoded.version
        history.previous = decoded.previous
        history.frequency = decoded.frequency
        history.lastPicked = decoded.lastPicked
        return history
    }

    // MARK: - Record Selection

    func recordSelection(_ stableID: String) {
        guard !stableID.isEmpty else { return }
        previous = stableID
        frequency[stableID, default: 0] += 1
        lastPicked[stableID] = Int64(Date().timeIntervalSince1970)
    }

    // MARK: - Frecency Scoring

    /// frecencyScore = frequency * (1.0 / (1.0 + hoursSince / 24.0))
    /// Returns 0 for unknown items.
    func frecencyScore(_ id: String) -> Double {
        guard let freq = frequency[id], freq > 0 else { return 0 }

        guard let lastTS = lastPicked[id], lastTS > 0 else {
            return Double(freq)
        }

        let hoursSince = Date().timeIntervalSince(Date(timeIntervalSince1970: Double(lastTS))) / 3600.0
        let recencyWeight = 1.0 / (1.0 + hoursSince / 24.0)
        return Double(freq) * recencyWeight
    }

    // MARK: - Source Boosts

    /// Source boost multipliers by item ID prefix.
    /// Windows (tmux:, ssh:, bundleID:, etc.) get highest priority at 10.0.
    static func sourceBoost(for id: String) -> Double {
        if id.hasPrefix("app:") { return 1.0 }
        if id.hasPrefix("chrome:") { return 1.0 }
        if id.hasPrefix("action:") { return 1.5 }
        if id.hasPrefix("zoxide:") { return 0.5 }
        // Windows: tmux:*, ssh:*, bundleID:*, unknown:*
        return 10.0
    }

    // MARK: - Sorting

    /// Sort items by finalScore = max(frecency, 1.0) * sourceBoost, descending.
    /// Uses stable sort to preserve original order for equal scores.
    func sortByFrecency(_ items: inout [PickerItem]) {
        // Use enumerated for stable sort tiebreaking
        let indexed = items.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let scoreA = finalScore(lhs.1.id)
            let scoreB = finalScore(rhs.1.id)
            if scoreA != scoreB {
                return scoreA > scoreB
            }
            // Equal scores: prefer higher priority, then preserve original order
            if lhs.1.priority != rhs.1.priority {
                return lhs.1.priority > rhs.1.priority
            }
            return lhs.0 < rhs.0
        }
        items = sorted.map { $0.1 }
    }

    /// Combined score: max(frecency, 1.0) * sourceBoost
    /// Base of 1.0 ensures source boosts apply even to items with no history.
    private func finalScore(_ id: String) -> Double {
        var base = frecencyScore(id)
        if base == 0 {
            base = 1.0
        }
        return base * Self.sourceBoost(for: id)
    }

    // MARK: - Pruning

    /// Remove oldest entries if over maxEntries, using lastPicked for LRU.
    func prune() {
        guard frequency.count > Self.maxEntries else { return }

        // Sort entries by lastPicked ascending (oldest first)
        let sorted = frequency.keys.sorted { a, b in
            (lastPicked[a] ?? 0) < (lastPicked[b] ?? 0)
        }

        // Remove oldest until at maxEntries
        let toRemove = sorted.count - Self.maxEntries
        for i in 0..<toRemove {
            let id = sorted[i]
            frequency.removeValue(forKey: id)
            lastPicked.removeValue(forKey: id)
        }
    }

    // MARK: - Save

    /// Atomic write: prune, write to .tmp, rename.
    func save() {
        prune()

        // Ensure state directory exists
        try? FileManager.default.createDirectory(
            atPath: thegridStateDir,
            withIntermediateDirectories: true
        )

        struct HistoryFile: Codable {
            var version: Int
            var previous: String
            var frequency: [String: Int]
            var lastPicked: [String: Int64]
        }

        let file = HistoryFile(
            version: version,
            previous: previous,
            frequency: frequency,
            lastPicked: lastPicked
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            jlog("pick.hist.encode_err")
            return
        }

        // Atomic write via temp file + rename
        let tmpPath = filePath + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath))
            try FileManager.default.moveItem(atPath: tmpPath, toPath: filePath)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
            jlog("pick.hist.save_err", data: ["err": "\(error)"])
        }
    }

    // MARK: - Helpers

    func isPrevious(_ id: String) -> Bool {
        return !previous.isEmpty && previous == id
    }
}
