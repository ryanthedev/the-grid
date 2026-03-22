# Discovery: Phase 1 - State Validator

## Files Found

Existing files relevant to this phase:

- `grid-server/Sources/GridServer/Grid/GridState.swift` -- actor with `removeWindow`, `removeWindowFromAllSpaces`, `getAllWindowIDs`, `removeSpace`, `findSpaceContaining`, and `displaySpaces` tracking
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- handles `systemWoke` event via `handleSystemWake`; has wake migration logic already
- `grid-server/Sources/GridServer/Grid/GridTypes.swift` -- type definitions (no changes needed)
- `grid-server/Sources/GridServer/MacOSAPIs.swift` -- `SLSGetWindowBounds` wrapper already exists and loaded (line 215-217); returns `CGError` (.failure for dead windows, .success for live ones)
- `grid-server/Sources/GridServer/StateModels.swift` -- `WindowState` has `isMinimized: Bool` and `spaces: [UInt64]` fields
- `grid-server/Sources/GridServer/StateManager.swift` -- `StateManager` actor with `getState() -> WindowManagerState`; wmState has `.spaces` keyed by space ID string, `.windows` keyed by window ID string
- `grid-server/Sources/GridServer/main.swift` -- wiring point; `gridState` and `gridReconciler` are created here

New file to create:
- `grid-server/Sources/GridServer/Grid/StateValidator.swift` -- new actor

## Current State

**GridState** is an actor with the following APIs directly relevant to this phase:
- `getAllWindowIDs() -> [UInt32]` -- returns all tracked window IDs (deduped across spaces)
- `removeWindowFromAllSpaces(_ windowID: UInt32)` -- removes a window from every space
- `removeWindow(_ windowID: UInt32, fromSpace spaceID: String)` -- removes from one space
- `removeSpace(_ spaceID: String)` -- removes a space entirely, marks dirty
- `findSpaceContaining(windowID: UInt32) -> String?` -- finds which space holds a window
- `spaces` dict (private) keyed by space ID string; iterated via `getAllWindowIDs` indirectly

**GridState also has `displaySpaces`**: a `[String: [String]]` (displayUUID -> [spaceID]) that is kept in sync during `migrateSpaceIDs` and persisted. This is the source of truth for which spaces are "known" -- but is NOT the set of currently-live spaces (wmState.spaces is).

**SLSGetWindowBounds** (MacOSAPIs.swift:215): `func SLSGetWindowBounds(_ cid: Int32, _ wid: UInt32, _ frame: UnsafeMutablePointer<CGRect>) -> CGError`. Returns `.failure` for destroyed windows. ASSUMPTION CONFIRMED: this is the correct liveness check.

**Minimized windows**: `WindowState.isMinimized: Bool` is available in wmState. The `StateManager.getState()` call returns current wmState so we can check `wmState.windows[String(wid)]?.isMinimized`. This is the fallback for distinguishing dead vs minimized. NOTE: SLSGetWindowBounds returns `.success` for minimized windows per the plan's medium-confidence assumption, so we must explicitly skip pruning minimized windows.

**wmState.spaces**: keyed by space ID string (e.g., "42"). Has `.displayUUID` and `.isActive`. This is the authoritative live space list. GridState may have spaces not in wmState (stale from before sleep/wake).

**handleSystemWake** in GridReconciler: already calls `gridState.migrateSpaceIDs` then `syncBordersForCurrentSpace`. StateValidator's `validate()` call will be added AFTER migration in this handler.

**Deduplication context**: `SpaceState` has `.windows: [UInt32]` (all windows on that space per OS). We can use this to find which space a duplicated window "should" be in (the space it actually appears on per wmState). The display's `currentSpaceID` tells us the active space per display.

## Gaps

1. **No StateValidator file exists** -- needs to be created.
2. **GridState has no `getSpaceIDs()` method** -- needed by validator to iterate all tracked spaces. Can add or use `exportState().spaces.keys` via existing `exportState()`.
3. **GridState displaySpaces is private** -- validator needs to know live spaces from wmState, not from GridState's displaySpaces. The validator takes wmState as a parameter, so this is fine -- it uses wmState.spaces.keys as the live set.
4. **No periodic timer in current code** -- validator owns a `DispatchSourceTimer` started from main.swift setup.
5. **GridReconciler.handleSystemWake** needs one new line to call validator.

## Assumption Verification

**SLSGetWindowBounds returns failure for destroyed windows (HIGH confidence):** Confirmed. The function is already loaded and used in the codebase (for border positioning). The `.failure` return value on a dead windowID is the established pattern in SLS private API usage across yabai, Amethyst, and the existing codebase.

**Minimized windows return success from SLSGetWindowBounds (MED confidence):** The `WindowState.isMinimized` field is present in StateModels.swift and populated by StateManager. We have the fallback available. Design decision: check `wmState.windows[String(wid)]?.isMinimized == true` before pruning to avoid removing minimized windows.

## Prerequisites

- [x] `GridState` actor exists with `removeWindowFromAllSpaces`, `removeWindow`, `removeSpace` APIs
- [x] `SLSGetWindowBounds` wrapper exists in MacOSAPIs.swift
- [x] `SLSMainConnectionID()` available (used in main.swift to initialize border manager -- same connectionID needed for validator)
- [x] `StateManager.getState()` returns wmState with `.spaces` (live space set) and `.windows` (with isMinimized)
- [x] `jlog` logging function available throughout
- [x] `GridReconciler.handleSystemWake` exists as the on-wake trigger point
- [x] `main.swift` wiring point for starting the periodic timer
- [x] No circular dependencies: StateValidator depends on GridState + StateManager (both actors), no backward references

## Recommendation

BUILD

The plan assumptions are accurate. All required APIs exist. The new file is `StateValidator.swift`. Minimal additions needed to `GridReconciler.handleSystemWake` (one await call) and `main.swift` (validator instantiation + timer start). No public API changes to GridState required -- existing methods cover all needs.

One design clarification needed: GridState has no public iterator over its space IDs. The validator needs this to check which tracked spaces are dead. Solution: use `getAllWindowIDs()` + `findSpaceContaining` is insufficient (we need to iterate spaces, not windows). Add a `getSpaceIDs() -> [String]` method to GridState -- it's a trivial one-liner exposing the private `spaces.keys`.
