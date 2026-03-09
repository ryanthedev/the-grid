# Pseudocode: Phase 4 - Wire deps in GridCommandRouter init

## Files to Modify
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` (init block only)

## Pseudocode

### GridCommandRouter.swift (init block, circular dependency resolution section)

```
// Existing circular dependency resolution (lines 122-124):
//   gridCellOps.setApply(gridApply)
//   gridWindowMove.setApply(gridApply)

// Add after the existing setApply calls:
// Wire GridApply into GridReconciler so it can apply cell layout after picker-launched window assignment
gridReconciler.setApply(gridApply)

// Wire GridFocus into GridReconciler so it can focus the newly assigned window
gridReconciler.setFocus(gridFocus)
```

## Design Notes
- This follows the identical pattern used by `gridCellOps` and `gridWindowMove` for circular dependency resolution via setter injection.
- Both `gridApply` and `gridFocus` are fully constructed by this point in init (setup() calls happen at lines 81-112, these setters are at lines 122+).
- The weak references in GridReconciler prevent retain cycles.
- No design-it-twice needed: there is exactly one correct place and pattern for this wiring.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (trivial wiring, follows existing pattern exactly)
- [x] Ready for implementation
