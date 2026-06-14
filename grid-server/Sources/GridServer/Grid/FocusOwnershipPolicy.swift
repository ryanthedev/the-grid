//
// FocusOwnershipPolicy.swift
// GridServer
//
// Phase 3 pure decision predicates for the focus-ownership path. Each helper is
// boundary-free (no AX/SkyLight) so the focus logic is unit-testable off the
// hot path. Callers (GridFocus, GridReconciler, WindowManipulator, StateManager)
// supply already-resolved scalars; these helpers decide.
//
//   FocusSequenceGate    — DW-3.5 (#17): reject stale (older-than-current) focus events.
//   classifyFocusResult  — DW-3.1 (#21): success only when every native step succeeded.
//   selectNonEmptyCandidate — DW-3.3 (#8): skip empty directional cells.
//   shouldSweepCorrect   — DW-3.4 (#13): focusSweep guard (fence + generation + suppression).
//   shouldSkipRestore    — DW-3.10 (#59s): restore-focus space-membership check (instrument-only).
//

import Foundation

// MARK: - FocusSequenceGate (DW-3.5, #17)

// Monotonic-sequence acceptance for focus events. AX/workspace notifications can
// be reordered by the global executor (one unstructured Task per callback), so a
// stale (older) focus event must not overwrite a newer one. The caller stamps
// each focus event with a monotonically increasing sequence and consults this
// gate before applying it.
enum FocusSequenceGate {

    // Apply the incoming event only when its sequence is newer than (or equal to,
    // for the first event) the last one applied. A strictly-older sequence is
    // rejected as stale.
    static func shouldApply(incomingSeq: UInt64, lastAppliedSeq: UInt64) -> Bool {
        return incomingSeq >= lastAppliedSeq
    }
}

// MARK: - Focus result classification (DW-3.1, #21)

// Outcome of the raise pipeline's native steps. The caller captures each native
// result; this value type carries them off the boundary for classification.
struct FocusRaiseOutcome {
    // GetProcessForPID succeeded (PSN resolved).
    let psnResolved: Bool
    // SLPSSetFrontProcessWithOptions returned .success.
    let slpsFrontSucceeded: Bool
    // The AX element for the window was obtained.
    let axElementPresent: Bool
    // AXUIElementPerformAction(kAXRaiseAction) returned .success.
    let axRaiseSucceeded: Bool
}

// Genuine focus success requires the front-process switch AND the AX raise to
// have landed on a real element. A missing AX element or a failed SLPS/AX call
// means focus did not actually change — the historical "always true" return is
// the #21 bug.
func classifyFocusResult(_ outcome: FocusRaiseOutcome) -> Bool {
    guard outcome.psnResolved else { return false }
    guard outcome.slpsFrontSucceeded else { return false }
    guard outcome.axElementPresent else { return false }
    guard outcome.axRaiseSucceeded else { return false }
    return true
}

// MARK: - Directional empty-cell skip (DW-3.3, #8)

// Pick the first directional candidate that actually contains windows.
// `orderedCandidates` is caller-ordered (closest first / wrap order);
// `cellWindowCounts` maps cellID -> live window count. Returns nil when every
// candidate is empty, signalling the caller to fall through to the next
// direction / wrap target instead of dead-ending on noWindowsInCell.
func selectNonEmptyCandidate(
    orderedCandidates: [String],
    cellWindowCounts: [String: Int]
) -> String? {
    for cellID in orderedCandidates {
        if (cellWindowCounts[cellID] ?? 0) > 0 {
            return cellID
        }
    }
    return nil
}

// MARK: - focusSweep guard (DW-3.4, #13)

// The 300ms focusSweep corrects GridState focus to match the OS. It must NOT
// fire while an action owns focus. This predicate gathers every reason to skip:
//   - the action path is suppressing reconciliation,
//   - the OS-focused window (or a cell-mate) is fenced by an in-flight move,
//   - the action generation changed across the sweep's awaits (a command began
//     after the sweep snapshotted state, so the sweep's read is stale).
// Returns true only when it is safe to write the correction.
func shouldSweepCorrect(
    osWindowFenced: Bool,
    cellMateFenced: Bool,
    genAtStart: UInt64,
    genNow: UInt64,
    suppressed: Bool
) -> Bool {
    if suppressed { return false }
    if osWindowFenced { return false }
    if cellMateFenced { return false }
    if genAtStart != genNow { return false }
    return true
}

// MARK: - restore-focus space-membership (DW-3.10, #59s — instrument-only)

// True when restoreFocusForSpace would raise a window that no longer belongs to
// the space being restored — which would yank the user off the space they just
// switched to. Used ONLY to emit win.focus.restore.skip instrumentation; the
// confirm-or-drop of the behavioral fix happens in UAT.
func shouldSkipRestore(windowSpaces: [UInt64], spaceID: UInt64) -> Bool {
    return !windowSpaces.contains(spaceID)
}
