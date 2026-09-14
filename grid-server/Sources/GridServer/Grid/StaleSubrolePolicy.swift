//
// StaleSubrolePolicy.swift
// GridServer
//
// Pure predicates for recovering windows lost to a cached transient subrole.
//

import Foundation

/// Decides which rejected windows are worth re-querying, and how often.
///
/// `isTileable` (GridAssignment.swift) answers from cached AX properties, and
/// `StateManager.updateWindowFromPoll` re-queries them only when `role == nil`.
/// A window whose app reported a transient `AXUnknown` subrole during startup
/// therefore has that value cached *with a real role*, so the requery guard
/// skips it forever and `isTileable` rejects it on the stale subrole for the
/// life of the window. 445 `AXWindow`/`AXUnknown` bails in one archived log, and
/// 16 windows confirmed lost: never tiled, yet still emitting real focus, move
/// and resize events. This is the defect documented at StateManager.swift:1650.
///
/// The in-tree note deferring that fix set three conditions, all met here:
///
/// * **Per-pid batching, not a per-window stall.** The caller groups by pid and
///   the AX presence check is one query per app.
/// * **Not purely additive, so scope it.** `isTileable` accepts an empty
///   subrole, so resolving one to `AXDialog`/`AXSheet` would *drop* a window
///   that tiles correctly today. Restricting the requery to windows that are
///   already rejected removes that risk entirely: they do not tile now, so a
///   refresh can only add one back, never take one away.
/// * **A budget, so a transient failure doesn't burn the retry forever.** A
///   genuinely-`AXUnknown` window stops being re-queried after a few attempts
///   rather than costing an AX round trip on every 300ms sweep.
enum StaleSubrolePolicy {

    /// How many times one window may be re-queried before we accept its subrole.
    static let maxAttempts = 3

    /// Whether this rejected window looks like a subrole-latch victim rather
    /// than a genuinely untileable one.
    ///
    /// The signature is narrow on purpose: a real `AXWindow` at real window
    /// dimensions whose *only* disqualification is the subrole. A popup, a
    /// tooltip or a system dialog fails on role or size and is never re-queried.
    static func looksStale(
        role: String?,
        subrole: String?,
        width: CGFloat,
        height: CGFloat,
        minDimension: Double
    ) -> Bool {
        guard role == "AXWindow" else { return false }
        guard subrole == "AXUnknown" else { return false }
        return Double(width) >= minDimension && Double(height) >= minDimension
    }

    /// Whether the window still has attempts left.
    static func shouldRetry(attempts: Int, maxAttempts: Int = maxAttempts) -> Bool {
        return attempts < maxAttempts
    }
}

/// Backoff for rejected windows the accessibility API will not expose.
///
/// A ghost -- a window whose process is alive but which AX no longer lists --
/// has no natural exit from `rejectedWindows`: SkyLight still reports its
/// bounds so `pruneDeadWindows` declines to remove it, and its cached `role`
/// stays latched tileable, so it re-enters the sweep's candidate list on every
/// tick. At the sweep's 300ms cadence that is a blocking AX round trip and a
/// log line roughly three times a second, indefinitely.
///
/// Exponential backoff capped at ~30s keeps the steady-state cost negligible
/// while still re-checking often enough that a window which genuinely comes
/// back is picked up promptly.
enum SweepBackoffPolicy {

    /// Sweep ticks to wait before re-querying, given consecutive absences.
    /// ~300ms per tick, so the cap is about 30 seconds.
    static let maxDelayTicks: UInt64 = 100

    static func delayTicks(streak: Int) -> UInt64 {
        guard streak > 0 else { return 0 }
        guard streak < 64 else { return maxDelayTicks }
        return min(UInt64(1) << UInt64(streak), maxDelayTicks)
    }
}
