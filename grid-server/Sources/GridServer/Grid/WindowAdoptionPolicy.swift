//
// WindowAdoptionPolicy.swift
// GridServer
//
// Phase 4 pure decision predicates for window creation, classification, and
// adoption. Extracted as static/free logic so the branches are unit-testable
// off the AX/SkyLight/timer boundary (per docs/code-standards.md).
//

import Foundation

/// Decides whether a created window may claim the armed pending-launch target.
///
/// Closes the pid-less first-come hole (#31/#18): before NSWorkspace fires the
/// launch completion the target.pid is nil, so the old code skipped the pid
/// check entirely and let the FIRST tileable window from ANY app claim the
/// cell. Matching on the picked app's bundle id instead means a foreign window
/// appearing during launch latency can no longer hijack the target.
enum PendingLaunchPolicy {

    /// Whether `windowBundleID`/`windowPID` may claim a target armed for
    /// `targetBundleID`/`targetPID`.
    ///
    /// - When the target PID is known, require a PID match (authoritative).
    /// - Else when the target bundle id is known, require a bundle-id match.
    /// - Else (no pid, no bundle id) the target is unconstrained — accept
    ///   (legacy behaviour; nothing better to match on).
    static func matchesTarget(
        windowBundleID: String?,
        targetBundleID: String?,
        windowPID: pid_t?,
        targetPID: pid_t?
    ) -> Bool {
        if let targetPID, targetPID != 0 {
            return windowPID == targetPID
        }
        if let targetBundleID, !targetBundleID.isEmpty {
            return windowBundleID == targetBundleID
        }
        return true
    }
}

/// Decides whether a tileable window that reached neither a cell nor the
/// rejected set should be adopted (DW-4.8 / #12). This is the terminal state of
/// a windowCreated dropped during suppression: StateManager has the window but
/// GridState never tiled it, and no existing sweep adopts it.
enum AdoptionPolicy {

    /// A window is an untracked tileable iff it is tileable and not assigned to
    /// any cell on any tracked space.
    static func isUntrackedTileable(isTileable: Bool, isAssignedAnywhere: Bool) -> Bool {
        return isTileable && !isAssignedAnywhere
    }
}

/// Decides whether a window misclassified as `not_standard` at creation should
/// be re-evaluated (#41). Apps that populate window buttons slightly after the
/// AX element appears read as button-less (floating) at creation; a short grace
/// window lets a later sweep re-classify them instead of a terminal bail.
enum NotStandardGracePolicy {

    /// Default grace window for not_standard re-evaluation.
    static let defaultGraceWindow: CFAbsoluteTime = 3.0

    /// True while the window is still within its grace window (re-evaluate);
    /// false once the grace has expired (give up and drop from tracking).
    static func shouldReevaluate(
        now: CFAbsoluteTime,
        firstSeen: CFAbsoluteTime,
        graceWindow: CFAbsoluteTime = defaultGraceWindow
    ) -> Bool {
        return (now - firstSeen) <= graceWindow
    }
}

/// Bounded backoff schedule for AX observer registration retries (#40). A
/// freshly launched app's AX server may not be up when the launch notification
/// fires; `observe()` returns false with kAXErrorCannotComplete. Retry a few
/// times with growing delay before giving up.
enum ObserverRetryPolicy {

    /// Delays (seconds) indexed by zero-based attempt number after the initial
    /// failure. Returns nil once retries are exhausted.
    static let delays: [TimeInterval] = [0.5, 1.0, 2.0]

    /// Delay before the given retry attempt (0 = first retry), or nil if no
    /// further retry should be scheduled.
    static func nextDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}
