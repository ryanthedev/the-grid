//
// FileGridStorage.swift
// GridServer
//
// Concrete GridStorage implementation that persists GridRuntimeStateData to a
// JSON file on disk. Extracted from GridState's former load/persistNow methods.
// Atomic write: encodes to a .tmp file then POSIX-renames to the final path.
//

import Foundation

// FileGridStorage conforms to GridStorage and Sendable.
// Immutable after init (statePath is the only stored property) — safe to share
// across concurrency domains.
struct FileGridStorage: GridStorage {

    let statePath: String

    init(path: String) {
        self.statePath = path
    }

    // MARK: - GridStorage

    func load() async throws -> GridRuntimeStateData? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: statePath) else {
            jlog("grid.state.load.new")
            return nil
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = FileGridStorage.dateFormatter.date(from: dateStr) {
                return date
            }
            if let date = FileGridStorage.dateFormatterFallback.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "cannot parse date: \(dateStr)"
            )
        }
        var decoded = try decoder.decode(GridRuntimeStateData.self, from: data)

        // Defensive nil-fill for cells dict (legacy state may omit it)
        for key in decoded.spaces.keys {
            if decoded.spaces[key]?.cells == nil {
                decoded.spaces[key]?.cells = [:]
            }
        }

        jlog("grid.state.load", data: ["spaceCount": decoded.spaces.count])
        return decoded
    }

    func save(_ data: GridRuntimeStateData) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let str = FileGridStorage.dateFormatter.string(from: date)
            try container.encode(str)
        }
        let encoded = try encoder.encode(data)

        let fm = FileManager.default
        let dir = (statePath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let tmpPath = statePath + ".tmp"
        try encoded.write(to: URL(fileURLWithPath: tmpPath))
        // POSIX rename atomically replaces destination
        if rename(tmpPath, statePath) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        jlog("grid.state.save")
    }

    // MARK: - Date Formatters (extracted from GridState)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormatterFallback: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
