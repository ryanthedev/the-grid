//
// BordersPolicy.swift
// GridServer
//
// Pure policy helpers for the borders subsystem.
// All helpers are static functions on value types — no SkyLight dependency,
// fully unit-testable without a display connection.
//

import Foundation

// MARK: - BorderMembershipPolicy

/// Determines whether the active cell's window membership changed between two assignment maps.
///
/// Used by setCellAssignmentsImpl to decide whether a full border rebuild is needed
/// when cell+focus+display are otherwise unchanged (the "silent delta drop" case, finding #9).
enum BorderMembershipPolicy {

    /// Returns true when the set of windows assigned to `cellID` differs between `old` and `new`.
    ///
    /// - Parameters:
    ///   - cellID: The currently active cell ID to inspect.
    ///   - old: The previous assignment map (nil = no prior assignments, always changed).
    ///   - new: The new assignment map.
    /// - Returns: `true` when rebuild is required; `false` when membership is identical.
    static func activeCellMembersChanged(
        cellID: String,
        old: [UInt32: String]?,
        new: [UInt32: String]
    ) -> Bool {
        guard let old = old else {
            // First-time assignment — treat as changed so borders are initialised.
            return true
        }
        let oldMembers = Set(old.filter { $0.value == cellID }.keys)
        let newMembers = Set(new.filter { $0.value == cellID }.keys)
        return oldMembers != newMembers
    }
}

// MARK: - BorderRetargetPolicy

/// Policy for BorderWindow.retarget: controls when targetWindowID should be committed.
///
/// Encodes the fix for finding #53: targetWindowID must only be committed AFTER
/// a successful bounds query, not before.
enum BorderRetargetPolicy {

    /// Returns true when the target window ID should be committed (bounds are available).
    ///
    /// - Parameter boundsAvailable: Whether SLSGetWindowBounds succeeded.
    static func shouldCommitTarget(boundsAvailable: Bool) -> Bool {
        return boundsAvailable
    }
}

// MARK: - BorderResizePolicy

/// Policy for BorderWindow.performUpdate resize-redraw path (finding #54).
///
/// When SLWindowContextCreate fails after a shape change, the border window has
/// alpha=0 but isVisible is still true. Setting isVisible=false allows the next
/// updateStyle/show call to repair visibility.
enum BorderResizePolicy {

    /// The jlog event code emitted when context creation fails during resize redraw.
    /// Must match the audit-spec log signature: "err.bdr.resize_ctx".
    static let resizeContextFailureLogEvent = "err.bdr.resize_ctx"

    /// Returns true: on context-create failure, isVisible should be cleared so the
    /// next update can repair the border.
    static func shouldClearVisibilityOnContextFailure() -> Bool {
        return true
    }
}

// MARK: - WindowOrderPrunePolicy

/// Policy for pruning a destroyed window from windowOrderPerDisplay (finding #56).
///
/// handleWindowDestroyedImpl prunes cellAssignmentsPerDisplay but not
/// windowOrderPerDisplay, inflating stack-indicator counts with dead window IDs.
enum WindowOrderPrunePolicy {

    /// Strips `wid` from every cell's ordered array within a windowOrder map.
    ///
    /// - Parameters:
    ///   - wid: The window ID to remove.
    ///   - windowOrder: A cellID → [windowID] map.
    /// - Returns: The map with `wid` removed from every cell's array.
    static func prune(
        wid: UInt32,
        from windowOrder: [String: [UInt32]]
    ) -> [String: [UInt32]] {
        return windowOrder.mapValues { $0.filter { $0 != wid } }
    }
}
