# Pseudocode: Phase 1 - Fix source space focus after removeWindow

## Files to Modify
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- `removeWindow()` method only

## Design

### Approach Considered

Only one approach makes sense here: update space-level focus inline in `removeWindow()` after the existing cell-level focus update. The cell already computes `lastFocusedIdx` and `lastFocusedWid` correctly -- the space just needs to mirror that.

Alternative: have callers explicitly call `setFocus()` after `removeWindow()`. Rejected because (a) it scatters responsibility, (b) callers would need to know whether the removed window was focused, and (c) `removeWindow` already handles cell-level focus internally, so space-level focus belongs here too.

### Depth Check
- Interface: no change (removeWindow signature unchanged)
- Hidden detail: callers don't need to know about focus fixup
- Common case: removeWindow just works, focus stays valid

## Pseudocode

### GridState.swift -- removeWindow()

After the existing cell-level focus update block (lines 403-438) and before the early return:

```
// After updating cell-level focus (lastFocusedIdx, lastFocusedWid, prevFocusedWid)
// and split ratios, fix space-level focus if the removed window's cell was focused

If space.focusedCell equals this cellID
    If cell is now empty
        Clear space.focusedCell to empty string
        Clear space.focusedWindow to 0
    Else
        // Cell still has windows; align space focus index with
        // the cell's already-corrected lastFocusedIdx
        Set space.focusedWindow to cell.lastFocusedIdx
    End if
End if

// (space is already written back to spaces[spaceID] and markDirty called)
```

Key points:
- The cell-level focus (`lastFocusedIdx`, `lastFocusedWid`) is already correctly updated by the existing code before we reach this point
- We only need to sync `space.focusedWindow` to match `cell.lastFocusedIdx`
- If the cell is empty, clear both `focusedCell` and `focusedWindow` so `getFocusedWindow()` returns 0
- We do NOT need to search for another cell to focus -- the space simply has no focused cell until the next focus event sets one
- This block must execute BEFORE the `spaces[spaceID] = space` write-back on line 437

### Placement detail

The new code goes inside the `for (cellID, var cell)` loop, after the splitRatios update (line 434) and before `space.cells[cellID] = cell` (line 436). The space-level update uses `cellID` from the loop and the already-updated `cell` struct.

## Design Notes

- `removeWindowInternal` has the same gap but does not need fixing in this phase. It operates on an `inout GridSpaceStateData` parameter that callers (`assignWindow`, `prependWindow`, `insertWindow`) immediately follow with explicit focus updates. Adding the fix there would be harmless but redundant.
- The `getFocusedWindow()` fallback to `cell.windows[0]` when `focusedWindow` is out of bounds is technically still reachable for other edge cases, but after this fix, `removeWindow` will no longer produce that state.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed
- [x] Ready for implementation
