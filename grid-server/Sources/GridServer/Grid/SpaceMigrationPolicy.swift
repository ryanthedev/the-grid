import Foundation

// SpaceMigrationPolicy: pure decision predicates for space migration and
// display-geometry reconfiguration. Extracted as `static` helpers so the
// logic is unit-testable off the AX/SkyLight boundary (code-standards §
// testing pattern). No I/O, no actor isolation, no side effects.
//
// Phase 2 findings: #2 (reassignment gate), #6 (numeric sort + significant-
// state destination guard), #24 (zero-bounds guard), #25/#62s (geometry diff).

// Named result of classifying a display's space change (OP-1: no bare bool).
enum SpaceChangeRouting: Equatable {
    // The old space ID is gone from the OS (true macOS reassignment, e.g.
    // a fullscreen-space create/destroy). GridState must migrate.
    case reassigned
    // The old space ID still exists — this is a plain desktop switch.
    // Nothing is migrated; the destination space is simply activated.
    case activated
}

enum SpaceMigrationPolicy {

    // #2: route .spaceIDReassigned ONLY when the old space ID no longer exists
    // in the refreshed OS space set. A plain desktop switch leaves the old ID
    // present, so it routes .spaceActivated and never migrates GridState.
    //
    // `refreshedSpaceIDs` is the set of space IDs that exist AFTER refreshSpaces
    // (string keys of state.spaces).
    static func classifySpaceChange(
        oldSpaceID: String,
        newSpaceID: String,
        refreshedSpaceIDs: Set<String>
    ) -> SpaceChangeRouting {
        // No-op transitions are treated as plain activations (no migration).
        if oldSpaceID == newSpaceID {
            return .activated
        }
        // The old ID surviving the refresh means macOS kept the space alive —
        // this is a desktop switch, not a reassignment.
        if refreshedSpaceIDs.contains(oldSpaceID) {
            return .activated
        }
        return .reassigned
    }

    // #6: numeric sort for positional space matching. The old code used
    // [String].sorted() which is lexicographic ("999" > "1001"), pairing the
    // wrong spaces on wake. Non-numeric IDs sort last, deterministically by
    // their string value, so the function is total.
    static func numericallySorted(_ ids: [String]) -> [String] {
        return ids.sorted { lhs, rhs in
            switch (UInt64(lhs), UInt64(rhs)) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                // numeric sorts before non-numeric
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs < rhs
            }
        }
    }

    // #51: a queued mutating command must confirm that the active space it
    // re-resolves immediately before acting still matches the space it resolved
    // at handler entry. A nil or mismatched current space means a switch landed
    // in between — the command must abort rather than hit the previous space.
    // Returns the confirmed space ID, or nil to abort.
    static func confirmActiveSpace(expected: String, current: String?) -> String? {
        guard let current, current == expected else {
            return nil
        }
        return current
    }

    // #26: a layout write must be aborted when the target space was migrated
    // (or closed) away DURING this apply — it existed in GridState when the
    // apply began but is gone now, so writing back would resurrect a zombie
    // space. The signal is the TRANSITION existed→gone, not mere absence:
    // a space that never existed at entry is simply being laid out for the
    // first time (e.g. after a state reset) and MUST be written — its GridState
    // entry is created by this very apply. Checking only `!spaceStillExists`
    // wrongly aborts every first-time apply (the regression this replaces).
    static func shouldAbortStaleWrite(
        spaceExistedAtEntry: Bool,
        spaceStillExists: Bool
    ) -> Bool {
        return spaceExistedAtEntry && !spaceStillExists
    }

    // #6: a migration may proceed only when the destination space does NOT
    // already hold significant grid state. Overwriting a laid-out destination
    // is the data-loss bug. The source must itself be significant (nothing to
    // migrate otherwise).
    static func canMigrate(
        sourceHasSignificantState: Bool,
        destinationHasSignificantState: Bool
    ) -> Bool {
        return sourceHasSignificantState && !destinationHasSignificantState
    }
}

// LayoutBoundsPolicy: #24 zero/degenerate display-bounds guard.
enum LayoutBoundsPolicy {

    // A rect is degenerate when it cannot support a real layout: non-positive
    // width or height, or any non-finite component. Tiling against such a rect
    // piles every window into the corner, so the caller must skip + log
    // instead of computing placements from it.
    static func isDegenerate(_ rect: CGRect) -> Bool {
        if !rect.origin.x.isFinite || !rect.origin.y.isFinite
            || !rect.size.width.isFinite || !rect.size.height.isFinite {
            return true
        }
        return rect.size.width <= 0 || rect.size.height <= 0
    }
}

// DisplayGeometryPolicy: #25/#62s geometry-only reconfiguration diff.
enum DisplayGeometryPolicy {

    // A display's geometry for diffing purposes: frame + visibleFrame.
    // nil frames compare equal to nil (no change), unequal to a present frame.
    struct Geometry: Equatable {
        let frame: CGRect?
        let visibleFrame: CGRect?
    }

    // #25: returns the UUIDs whose frame or visibleFrame changed between two
    // snapshots keyed by display UUID. A UUID present in only one snapshot is
    // a connect/disconnect (handled elsewhere) and is NOT reported here — this
    // predicate detects geometry-only changes for displays present in both.
    static func changedDisplays(
        old: [String: Geometry],
        new: [String: Geometry]
    ) -> [String] {
        var changed: [String] = []
        for (uuid, newGeo) in new {
            guard let oldGeo = old[uuid] else { continue }
            if oldGeo != newGeo {
                changed.append(uuid)
            }
        }
        return changed.sorted()
    }
}
