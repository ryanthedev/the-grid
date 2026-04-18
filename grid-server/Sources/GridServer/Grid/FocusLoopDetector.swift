//
// FocusLoopDetector.swift
// GridServer
//
// Detects focus ping-pong between two window IDs. Used by GridFocus to bail
// out of unbounded focus.mismatch retries when the OS keeps re-stealing focus
// to the same other window within a short time window.
//
// Pure logic; all inputs injected. Callers pass CFAbsoluteTimeGetCurrent().
//

import Foundation

struct FocusLoopDetector {

    // Unordered window pair — (100,200) and (200,100) hash the same.
    struct PairKey: Hashable {
        let low: UInt32
        let high: UInt32

        init(_ a: UInt32, _ b: UInt32) {
            self.low = min(a, b)
            self.high = max(a, b)
        }
    }

    struct Entry {
        let pair: PairKey
        let ts: CFAbsoluteTime
    }

    // Trip detection parameters (per plan: 3 same-pair flips within 2s).
    // "bail after 3 cycles" reads as "on the 4th observation of a looping pair".
    private let windowSec: CFAbsoluteTime = 2.0
    private let threshold: Int = 3

    private var recent: [Entry] = []

    // Observe a (requested, actual) focus mismatch event.
    //
    // Returns nil if this pair has not yet reached the trip threshold within
    // the 2s window — caller should proceed with the normal retry path.
    //
    // Returns (count, durationMs) when the same pair has been observed more
    // than `threshold` times inside the window — caller should bail and log
    // focus.loop instead of retrying.
    mutating func observe(
        requested: UInt32,
        actual: UInt32,
        now: CFAbsoluteTime
    ) -> (count: Int, durationMs: Int)? {
        let pair = PairKey(requested, actual)

        // Prune entries outside the window (older than `windowSec`).
        // Also handle clock-goes-backward: treat any entry with ts > now as stale.
        recent.removeAll { entry in
            let age = now - entry.ts
            return age > windowSec || age < 0
        }

        // Append the current observation.
        recent.append(Entry(pair: pair, ts: now))

        // Count how many entries share this pair within the window.
        let samePair = recent.filter { $0.pair == pair }
        if samePair.count > threshold {
            let first = samePair.first!.ts
            let last = samePair.last!.ts
            let durationMs = Int((last - first) * 1000.0)
            return (count: samePair.count, durationMs: durationMs)
        }

        return nil
    }
}
