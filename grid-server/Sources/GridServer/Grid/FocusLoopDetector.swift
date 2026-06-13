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

    // Suppression window after a per-requested trip (DW-3.7, #43): once a
    // requested window trips, further attempts for it are suppressed for this
    // long instead of issuing another raise on every command.
    private let suppressSec: CFAbsoluteTime = 1.0

    private var recent: [Entry] = []

    // Per-requested-window observations (DW-3.7, #43). Unlike `recent` (pair-
    // keyed), this keys on the REQUESTED window so a rotation among 3+ windows
    // (A->B->C->A) trips on requested=A recurring. nil-actual is recorded too.
    private struct ReqEntry {
        let requested: UInt32
        let ts: CFAbsoluteTime
    }
    private var recentRequested: [ReqEntry] = []

    // requested window -> time until which it is suppressed after a trip.
    private var suppressedUntil: [UInt32: CFAbsoluteTime] = [:]

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

    // Observe a focus attempt keyed on the REQUESTED window (DW-3.7, #43).
    //
    // Differs from observe(pair) in three ways the pair-keyed path could not
    // catch:
    //   (1) nil `actual` (the focused window was cleared, e.g. destroy mid-
    //       command) is still observed instead of bypassing detection;
    //   (2) keying on `requested` trips on a 3+ window rotation A->B->C->A,
    //       which never reaches the pair threshold for any single pair;
    //   (3) after a trip, the requested window is suppressed for `suppressSec`
    //       so the caller bails (no further raise) instead of one-raise-per-call.
    //
    // Returns (count, durationMs) on a trip OR while suppressed; nil to proceed.
    mutating func observeRequested(
        requested: UInt32,
        actual: UInt32?,
        now: CFAbsoluteTime
    ) -> (count: Int, durationMs: Int)? {
        // Still suppressed from a recent trip -> bail without re-observing.
        if let until = suppressedUntil[requested] {
            if now <= until && now >= until - suppressSec {
                return (count: threshold + 1, durationMs: 0)
            }
            // Suppression elapsed (or clock moved) -> clear it.
            suppressedUntil.removeValue(forKey: requested)
        }

        // Prune entries outside the window (and clock-backward guard).
        recentRequested.removeAll { entry in
            let age = now - entry.ts
            return age > windowSec || age < 0
        }

        recentRequested.append(ReqEntry(requested: requested, ts: now))

        let sameReq = recentRequested.filter { $0.requested == requested }
        if sameReq.count > threshold {
            let first = sameReq.first!.ts
            let last = sameReq.last!.ts
            let durationMs = Int((last - first) * 1000.0)
            // Arm the suppression window so subsequent attempts bail quietly.
            suppressedUntil[requested] = now + suppressSec
            return (count: sameReq.count, durationMs: durationMs)
        }

        return nil
    }
}

// MARK: - FocusLoopActor (DW-3.6, #35)

// Actor wrapper isolating the detector's mutable state. GridFocus previously
// held a bare FocusLoopDetector struct mutated from the command path, the event
// path, and the 300ms sweep concurrently — an Array CoW data race. Routing every
// observation through this actor serializes the mutations.
actor FocusLoopActor {
    private var detector = FocusLoopDetector()

    // Pair-keyed observation (legacy mismatch path).
    func observe(
        requested: UInt32,
        actual: UInt32,
        now: CFAbsoluteTime
    ) -> (count: Int, durationMs: Int)? {
        detector.observe(requested: requested, actual: actual, now: now)
    }

    // Per-requested-window observation (DW-3.7).
    func observeRequested(
        requested: UInt32,
        actual: UInt32?,
        now: CFAbsoluteTime
    ) -> (count: Int, durationMs: Int)? {
        detector.observeRequested(requested: requested, actual: actual, now: now)
    }
}
