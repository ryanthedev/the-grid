# Pseudocode: Phase 2 - Wire up mouse warp for window move and swap

## Files to Modify
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift`

## Files Already Done (no changes needed)
- `GridCommandRouter.swift` -- swap case, warpMouseToFocusedWindow helper, move case flag parsing all done
- `GridCellOps.swift` -- swapWindow already works, mouse warp handled by router

## Design: Threading warpMouse

### Approaches Considered
1. **Warp in router after moveWindow returns** -- Router calls warpMouseToFocusedWindow() after moveWindow(). Simple but reads stale wmState (window just moved, snapshot not refreshed).
2. **Thread warpMouse bool into private methods** -- Pass warpMouse to moveWindowToCell/moveWindowCrossDisplay, warp using already-calculated cell bounds. Accurate, minimal overhead.
3. **Make moveWindow return cell bounds** -- Return target cell bounds in GridMoveResult, let router warp. Clutters the result type for a single consumer.

### Comparison
| Criterion | A (router) | B (thread bool) | C (return bounds) |
|-----------|-----------|-----------------|-------------------|
| Accuracy | Poor (stale frame) | Good (cell bounds available) | Good |
| Code changes | 1 file, 2 lines | 1 file, ~8 lines | 2 files, ~12 lines |
| Interface simplicity | No signature change | +1 param to 2 private methods | Changes public result type |
| Information hiding | Leaks timing concern to router | Keeps warp logic with move logic | Leaks layout detail to router |

### Choice: B (thread warpMouse bool into private methods)
Rationale: Cell bounds are already calculated in both move methods. Adding one bool parameter is minimal. Keeps the warp decision close to the data it needs. Private methods so no public API change.

### Depth Check
- Public interface: unchanged (moveWindow takes GridMoveOpts which already has warpMouse)
- Hidden details: cell bounds calculation, warp point computation
- Common case complexity: simple -- one extra bool check at end of each method

## Pseudocode

### GridWindowMove.swift

#### moveWindow() -- pass warpMouse through to private methods

```
// In moveWindow(), at the call to moveWindowCrossDisplay (line ~176):
// Add warpMouse parameter
result = moveWindowCrossDisplay(
    direction, windowID, sourceCell, cellBounds, wmState, spaceID,
    warpMouse: opts.warpMouse    // NEW
)

// In moveWindow(), at the call to moveWindowToCell (line ~210):
// Add warpMouse parameter
result = moveWindowToCell(
    windowID, sourceCell, targetCell, spaceID, layoutDef, displayBounds, wmState,
    warpMouse: opts.warpMouse    // NEW
)
```

#### moveWindowToCell() -- accept warpMouse, warp after focus

```
// Add warpMouse parameter to signature
private func moveWindowToCell(
    windowID, sourceCell, targetCell, spaceID, layoutDef, displayBounds, wmState,
    warpMouse: Bool = false    // NEW parameter with default
) async throws -> GridMoveResult

// After step 10 (focus the moved window, line ~317), before step 11 (border sync):
// If warpMouse requested, warp cursor to target cell center
if warpMouse {
    // calculated.cellBounds is available from step 3 (line ~250)
    // Get target cell bounds and warp to center
    if let targetBounds = calculated.cellBounds[targetCell] {
        // Apply display offset to get screen coordinates
        let warpPoint = CGPoint(
            x: targetBounds.midX + offset.x,
            y: targetBounds.midY + offset.y
        )
        CGWarpMouseCursorPosition(warpPoint)
    }
}
```

#### moveWindowCrossDisplay() -- accept warpMouse, warp after focus

```
// Add warpMouse parameter to signature
private func moveWindowCrossDisplay(
    direction, windowID, sourceCell, currentCellBounds, wmState, spaceID,
    warpMouse: Bool = false    // NEW parameter with default
) async throws -> GridMoveResult

// After step 11 (focus the moved window, line ~454), before step 12 (border sync):
// If warpMouse requested, warp cursor to target cell center on target display
if warpMouse {
    // targetCellBounds is available from step 3 (line ~385)
    // targetDisplayBounds is available from step 4 (line ~392)
    if let targetBounds = targetCellBounds[targetCell] {
        let warpPoint = CGPoint(
            x: targetBounds.midX,
            y: targetBounds.midY
        )
        CGWarpMouseCursorPosition(warpPoint)
    }
}
```

Note on coordinate systems: `targetCellBounds` from `getDisplayCells()` returns bounds in screen coordinates (already includes display position), so no offset adjustment needed for cross-display. For same-display `moveWindowToCell`, `calculated.cellBounds` are relative to `displayBounds` origin, and the display offset from config is an additional shift (for menu bar, etc.), so we add it.

Actually -- re-examining: `GridLayout.calculateLayoutWithRatios` takes `screenRect: displayBounds` and produces cell bounds in screen coordinates (the display's visible frame already positions them). The `offset` from config is an additional per-display nudge. So for same-display, `targetBounds.midX + offset.x` is correct. For cross-display, `targetCellBounds` comes from `getDisplayCells` which also calculates in screen coordinates, but without the config offset applied. We should apply the target display's offset there too.

Revised cross-display warp:
```
if warpMouse {
    if let targetBounds = targetCellBounds[targetCell] {
        // Get target display's config offset
        let targetDisplayName = adjacentDisplay.name ?? ""
        let targetOffset = await MainActor.run {
            gridConfig.getDisplayOffset(uuid: adjacentDisplay.uuid, name: targetDisplayName)
        }
        let warpPoint = CGPoint(
            x: targetBounds.midX + targetOffset.x,
            y: targetBounds.midY + targetOffset.y
        )
        CGWarpMouseCursorPosition(warpPoint)
    }
}
```

Wait -- actually, display offsets are typically small menu-bar/dock adjustments. The warp just needs to land roughly in the cell center. The offset is for window placement precision, not cursor position. And `CGWarpMouseCursorPosition` uses global screen coordinates which the cell bounds already are. Skip the offset for warp -- it's a cursor position, not a window frame. Simplify:

```
// Same-display (moveWindowToCell):
if warpMouse, let targetBounds = calculated.cellBounds[targetCell] {
    CGWarpMouseCursorPosition(CGPoint(x: targetBounds.midX, y: targetBounds.midY))
}

// Cross-display (moveWindowCrossDisplay):
if warpMouse, let targetBounds = targetCellBounds[targetCell] {
    CGWarpMouseCursorPosition(CGPoint(x: targetBounds.midX, y: targetBounds.midY))
}
```

This matches the pattern in `GridFocus.warpMouseToCell` which also just uses `bounds.center` without offset.

## Design Notes
- Display offset is NOT applied to warp position -- it is a window placement adjustment, not a cursor adjustment. Cell bounds in screen coordinates are sufficient for cursor warp.
- Default value `warpMouse: Bool = false` means existing callers (if any) don't break, though both call sites are private to this class.
- The warp happens AFTER focus but BEFORE border sync, so the cursor is visually in the right place when borders appear.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (design-it-twice comparison above)
- [x] Ready for implementation
