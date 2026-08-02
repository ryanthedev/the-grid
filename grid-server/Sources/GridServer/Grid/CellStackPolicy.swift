//
// CellStackPolicy.swift
// GridServer
//
// Pure decision functions for intra-cell window stacking, extracted off
// GridCellOps' actor/async surface so they can be unit-tested directly.
//
// A cell holds an ordered list of windows; the stack mode decides how that
// order is painted (vertical = top→bottom, horizontal = left→right, tabs =
// overlaid). Every function here operates on that index order alone — no
// GridState, no layout geometry, no AX.
//
// Extracted after a mutation campaign left GridCellOps at 0%: the
// direction→delta sign, the layout stack-mode lookup, and the split-ratio
// guard all had mutants that no test could see.
//

import Foundation

enum CellStackPolicy {

    // Index-order swap target, with wraparound.
    //
    // `.up` and `.left` move a window toward index 0; `.down` and `.right`
    // move it toward the end. That mapping is deliberately mode-independent.
    // The on-axis direction differs per mode (vertical stacks answer to
    // up/down, horizontal and tabs to left/right), but the off-axis direction
    // is accepted as an alias rather than rejected, so all four arrow keys
    // stay live in every mode — bfd binds ctrl+alt-h/j/k/l to `window swap`
    // for all four directions, and cross-cell movement is a separate command
    // (`window move`). Rejecting off-axis input here would silently break two
    // of those four bindings depending on the focused cell's mode.
    //
    // windowCount must be >= 1; callers guard on >= 2 before swapping.
    static func swapTargetIndex(
        currentIdx: Int,
        windowCount: Int,
        direction: GridDirection
    ) -> Int {
        guard windowCount > 0 else { return 0 }
        let delta = (direction == .up || direction == .left) ? -1 : 1
        return ((currentIdx + delta) % windowCount + windowCount) % windowCount
    }

    // Stack mode declared by a layout for one cell, or nil if it declares none.
    //
    // Cell-level `stackMode` wins over the layout's `cellModes` map. A cell
    // entry with a nil stackMode is not a match — the cellModes map still gets
    // its turn. Callers layer this between the runtime override (highest) and
    // the settings default (lowest).
    static func stackModeFromLayout(
        cellID: String,
        cells: [GridCellDef],
        cellModes: [String: GridStackMode]
    ) -> GridStackMode? {
        for cell in cells {
            if cell.id == cellID, let mode = cell.stackMode {
                return mode
            }
        }
        return cellModes[cellID]
    }

    // Split ratios with two entries swapped, or nil when the ratio array does
    // not describe this window list (stale or never initialised) and must be
    // left alone rather than reordered against the wrong windows.
    static func swappedSplitRatios(
        _ ratios: [Double],
        windowCount: Int,
        _ i: Int,
        _ j: Int
    ) -> [Double]? {
        guard ratios.count == windowCount else { return nil }
        guard ratios.indices.contains(i), ratios.indices.contains(j) else { return nil }
        var out = ratios
        out.swapAt(i, j)
        return out
    }
}
