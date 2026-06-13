//
// GraceWindowPolicy.swift
// GridServer
//
// Pure decision predicates for the two SLS-lag grace windows. The SLS-fallback
// space query (getWindowSpace / wmState.windows[wid].spaces) lags an async
// move by up to one poll interval (~3s); both predicates answer "is this
// timestamp recent enough to still be inside its grace window?" so callers can
// suppress an action that the lagging query would otherwise misfire.
//
// Extracted off the OS boundary and unit-tested directly (no AX/SLS, no
// reconciler/actor stack). Both checks are number-line in-range tests with a
// nil guard for the optional timestamp.
//

import Foundation

enum GraceWindowPolicy {

    // Shared in-range test. A nil stamp means "no event recorded" — neutral
    // false. Otherwise the stamp is inside the window when the elapsed time is
    // strictly less than the grace; exactly-at-grace is already expired.
    private static func withinGrace(
        stamp: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        graceSeconds: CFAbsoluteTime
    ) -> Bool {
        guard let stamp else { return false }
        return (now - stamp) < graceSeconds
    }

    // DW-D1: a window deliberately moved across spaces is exempt from
    // displaced-sweep correction until the grace expires (by which time the
    // lagging SLS space query catches up). nil ⇒ false; recent ⇒ true;
    // at/after grace ⇒ false.
    static func withinCrossMoveGrace(
        movedAt: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        graceSeconds: CFAbsoluteTime
    ) -> Bool {
        withinGrace(stamp: movedAt, now: now, graceSeconds: graceSeconds)
    }

    // DW-D3: a genuine resurrection is a window that was REMOVED from state and
    // then re-added by a poll whose snapshot predated the removal — i.e. the
    // removal tombstone is still within the grace window. nil ⇒ false (never
    // removed); recent ⇒ true; expired ⇒ false (poll legitimately rediscovered).
    static func isResurrection(
        removedAt: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        graceSeconds: CFAbsoluteTime
    ) -> Bool {
        withinGrace(stamp: removedAt, now: now, graceSeconds: graceSeconds)
    }
}
