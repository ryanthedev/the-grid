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
