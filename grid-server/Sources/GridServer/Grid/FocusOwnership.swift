//
// FocusOwnership.swift
// GridServer
//
// Cross-actor flag: a grid action currently owns focus.
//

import Foundation

/// Whether an action path (layout apply, picker, terminal, focus command) is
/// mid-flight and owns focus.
///
/// `GridReconciler` already tracks this as `suppressionDepth` and uses it to
/// drop external focus events -- the `reconcile.focus.suppressed` line. But the
/// reconciler is not the only consumer of a focus event: `StateManager` handles
/// the same event and applied it unconditionally, so a focus the reconciler had
/// correctly declined still landed in `state.metadata` (focusedWindowID, active
/// display, active space) and was persisted as the space's
/// `lastFocusedWindowID`. The guard existed, on one of the two consumers.
///
/// Both are actors and neither may block on the other, so the flag lives here:
/// a lock-guarded counter, written by the action path and read synchronously by
/// anyone handling an event. Modelled on `FocusEventSequence`, which solves the
/// same cross-actor ordering problem for sequence stamps.
///
/// Refcounted rather than boolean because actions nest (a layout apply inside a
/// focus command), matching `suppressionDepth`.
final class FocusOwnership: @unchecked Sendable {

    static let shared = FocusOwnership()

    private let lock = NSLock()
    private var depth: Int = 0

    private init() {}

    /// Mirror the action path's suppression depth.
    ///
    /// Set from a single `didSet` on `GridReconciler.suppressionDepth` rather
    /// than incremented at each of its five mutation sites, so the two counts
    /// cannot drift. Clamped at zero: the action path has logged more
    /// `action.start` than `action.end` (24 unmatched across one archived log),
    /// and a negative count would wedge the flag permanently off.
    func set(depth newDepth: Int) {
        lock.lock()
        depth = max(0, newDepth)
        lock.unlock()
    }

    /// True while any action owns focus.
    var isOwned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    // Test seam: force the flag to a known state.
    func _test_reset(depth newDepth: Int = 0) {
        lock.lock()
        depth = max(0, newDepth)
        lock.unlock()
    }
}
