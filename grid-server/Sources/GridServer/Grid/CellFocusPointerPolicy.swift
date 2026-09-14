//
// CellFocusPointerPolicy.swift
// GridServer
//
// Pure decision predicates for a cell's focus pointer (`lastFocusedWid` /
// `lastFocusedIdx`). Extracted off the actor so the rules are unit-testable
// (per docs/code-standards.md).
//

import Foundation

/// Owns the two rules that keep a cell's focus pointer honest.
///
/// The pointer is the pair (`lastFocusedWid`, `lastFocusedIdx`), read back by
/// `GridFocus.focusCellByID` with priority `lastFocusedWid > lastFocusedIdx >
/// first window`. Two defects lived in the hand-rolled maintenance of that pair:
///
/// 1. **Every insert claimed the pointer unconditionally.** `assignWindow`,
///    `prependWindow` and `insertWindow` each ended with
///    `cell.lastFocusedWid = windowID`, so the *last window added to a cell*
///    became the cell's focus target -- including a window the reconciler added
///    as bookkeeping (adoption, locked-cell create, lift migration, rejected
///    sweep). Entering that cell then focused the new arrival instead of the
///    window the user last used there. Every deliberate placement path
///    (`GridCellOps`, `GridWindowMove`, picker placement) already calls
///    `setFocus()` immediately after inserting, so the implicit claim was
///    redundant exactly where it was wanted and wrong everywhere else.
///
/// 2. **`lastFocusedIdx` desynced from `lastFocusedWid`.** Removal only
///    *clamped* the index when it ran past the end, never decremented it when a
///    window ahead of it was removed; a prepend shifted every element right
///    without touching it at all. The stale index is masked while
///    `lastFocusedWid` still resolves, and surfaces the moment it is cleared --
///    focusing an arbitrary window, silently.
enum CellFocusPointerPolicy {

    /// Whether a window arriving in a cell should claim that cell's focus
    /// pointer. Only a cell with no pointer at all (empty, or every prior
    /// occupant gone) has one to give: otherwise the incumbent stands and the
    /// caller must go through `setFocus` to move it deliberately.
    static func shouldClaimOnInsert(currentLastFocusedWid: UInt32) -> Bool {
        return currentLastFocusedWid == 0
    }

    /// The index the pointer should hold for `windows`, given the wid it names.
    ///
    /// Resolving the index *from the wid* rather than patching it arithmetically
    /// at each mutation site makes the pair self-healing: any insert, remove or
    /// reorder converges on the next call, and the index can only be wrong when
    /// there is no wid to resolve against (where it is clamped into range).
    static func resolveIndex(
        windows: [UInt32],
        lastFocusedWid: UInt32,
        lastFocusedIdx: Int
    ) -> Int {
        guard !windows.isEmpty else { return 0 }
        if lastFocusedWid != 0, let idx = windows.firstIndex(of: lastFocusedWid) {
            return idx
        }
        return max(0, min(lastFocusedIdx, windows.count - 1))
    }
}
