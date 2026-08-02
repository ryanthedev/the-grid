//
// LogRotationPolicy.swift
// GridServer
//
// Pure decisions for size-based rotation of the JSONL server log, extracted
// off JSONLogWriter's filesystem surface so they can be unit-tested without
// writing files.
//
// The server had no rotation of any kind: thegrid-server.json reached 411 MB
// on this machine before anyone looked. Rotation is checked on the batch
// write path, which already opens the file fresh each time.
//

import Foundation

enum LogRotationPolicy {

    // Default ceiling per file and number of archives kept alongside it. The
    // live file plus `keep` archives bounds total log usage at
    // maxBytes * (keep + 1). Both are overridable via THEGRID_LOG_MAX_BYTES
    // and THEGRID_LOG_KEEP.
    static let defaultMaxBytes = 32 * 1024 * 1024
    static let defaultKeep = 5

    // Rotate when this batch would push the file past its ceiling.
    //
    // An empty file never rotates, even if the incoming batch alone exceeds
    // maxBytes — otherwise a single oversized batch would rotate on every
    // write and shred the archives without ever storing anything. A maxBytes
    // of zero or less disables rotation entirely.
    static func shouldRotate(currentBytes: Int, incomingBytes: Int, maxBytes: Int) -> Bool {
        guard maxBytes > 0 else { return false }
        guard currentBytes > 0 else { return false }
        return currentBytes + incomingBytes > maxBytes
    }

    // The rename sequence that shifts the archive chain down by one, ordered
    // oldest-first so no rename overwrites a file the next one still needs:
    // keep = 3 yields base.2 -> base.3, base.1 -> base.2, base -> base.1.
    //
    // The caller deletes base.<keep> first; it is the one that ages out.
    // A keep of zero or less yields no renames, meaning the live file is
    // simply discarded with no history.
    static func rotationRenames(base: String, keep: Int) -> [(from: String, to: String)] {
        guard keep > 0 else { return [] }
        var renames: [(from: String, to: String)] = []
        var index = keep - 1
        while index >= 1 {
            renames.append((from: "\(base).\(index)", to: "\(base).\(index + 1)"))
            index -= 1
        }
        renames.append((from: base, to: "\(base).1"))
        return renames
    }

    // Apply the rename sequence on disk. Split out from JSONLogWriter so the
    // shifting can be driven against a temp directory in tests; the writer
    // calls this from its serial queue.
    //
    // `keep <= 0` discards the live file with no history.
    static func performRotation(base: String, keep: Int, fileManager fm: FileManager = .default) {
        let renames = rotationRenames(base: base, keep: keep)
        guard !renames.isEmpty else {
            try? fm.removeItem(atPath: base)
            return
        }
        // The oldest archive ages out; moveItem refuses an existing target.
        try? fm.removeItem(atPath: "\(base).\(keep)")
        for rename in renames where fm.fileExists(atPath: rename.from) {
            try? fm.moveItem(atPath: rename.from, toPath: rename.to)
        }
    }

    // Read an integer tuning knob from the environment, falling back to the
    // default when unset or unparseable. A negative value is passed through so
    // callers can disable rotation with THEGRID_LOG_MAX_BYTES=0.
    static func envInt(_ name: String, default fallback: Int, environment: [String: String]) -> Int {
        guard let raw = environment[name]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty,
              let value = Int(raw) else {
            return fallback
        }
        return value
    }
}
