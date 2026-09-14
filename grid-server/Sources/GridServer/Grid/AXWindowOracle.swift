//
// AXWindowOracle.swift
// GridServer
//
// The single live-AX answer to "does this window still exist?", shared by the
// code that adopts windows and the code that prunes them.
//

import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<UInt32>
) -> AXError

/// Live per-pid window-id lookup through the accessibility API.
///
/// This exists because adoption and pruning used to consult *different*
/// oracles, and spent six days contradicting each other. `StateValidator`
/// pruned windows absent from their app's live AX window list (`ax_orphan`),
/// while `GridReconciler.adoptUntrackedTileables` re-adopted them based only on
/// the cached `WindowState.role` -- a field that latches at discovery and is
/// re-queried only when nil, so it never learns that a window died. Four kitty
/// windows whose processes were alive but exposed zero AX windows cycled
/// adopt -> prune -> adopt 154 times each, and while they sat in a cell they
/// broke directional focus and failed layout placement.
///
/// Both halves now ask this. The deliberate asymmetry is in the failure case:
/// a nil answer means "we could not find out", and *both* callers must then do
/// nothing -- prune nothing, adopt nothing. Agreeing to abstain is what stops
/// them ping-ponging.
///
/// Stateless by design: both callers are actors, and each already groups its
/// candidates by pid, so batching belongs at the call site rather than in a
/// shared mutable cache that would have to be made sendable.
enum AXWindowOracle {

    /// Classify a failed `kAXWindows` query.
    ///
    /// The only thing separating "this process genuinely owns no windows, an
    /// empty set is accurate" from "the app is busy or unreachable, we know
    /// nothing" -- and getting it backwards makes every window of an
    /// unresponsive app look orphaned, which prunes all of them after two
    /// cycles.
    ///
    /// - Returns: true => report an empty set; callers may treat the app's
    ///   windows as absent. false => report nil; callers must skip this pid.
    static func axFailureMeansNoWindows(_ result: AXError) -> Bool {
        // .attributeUnsupported = non-windowed process (agent/daemon), definitive.
        // .cannotComplete / .notImplemented / anything else = app busy or
        // unusual, and absence of evidence is not evidence of absence.
        return result == .attributeUnsupported
    }

    /// Every window id `pid` currently exposes over AX.
    ///
    /// - Returns: nil when the query failed in a way that carries no
    ///   information (see `axFailureMeansNoWindows`). Callers must treat nil as
    ///   "unknown" and change nothing, never as "no windows".
    static func windowIDs(pid: pid_t) -> Set<UInt32>? {
        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return axFailureMeansNoWindows(result) ? Set() : nil
        }

        var ids = Set<UInt32>()
        for window in windows {
            var windowID: UInt32 = 0
            if _AXUIElementGetWindow(window, &windowID) == .success {
                ids.insert(windowID)
            }
        }
        return ids
    }
}
