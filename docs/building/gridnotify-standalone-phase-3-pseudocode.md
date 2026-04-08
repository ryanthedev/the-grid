# Pseudocode: Phase 3 — Locked Cell Support in grid-server

## DW Coverage Map

| DW ID | Section |
|-------|---------|
| DW-3.1 | Section 1: Config (YAML + runtime struct + parsing) |
| DW-3.2 | Section 2: Assignment (skip locked cells for non-matching) |
| DW-3.3 | Section 2: Assignment (auto-assign matching), Section 3: Reconciler |
| DW-3.4 | Section 1: Config (default rule) |
| DW-3.5 | Section 2: Assignment (locked=false means no change to existing behavior) |

---

## Section 1: Config Changes — `GridConfig.swift`

### DW-3.1: Add `locked` field to YAML and runtime structs

```
GridAppRuleYAML:
  add field: locked: Bool? (optional, Codable)

GridAppRule:
  add field: locked: Bool (non-optional, defaults to false)
```

### DW-3.1: Parse locked flag

In `parseAppRules`:
```
when mapping GridAppRuleYAML -> GridAppRule:
  locked = r.locked ?? false
```

### DW-3.4: Default app rules for com.thegrid.notify

After parsing user app rules, append built-in defaults that aren't overridden:

```
FUNCTION appendBuiltinAppRules():
  builtinRules = [
    GridAppRule(
      app: "com.thegrid.notify",
      preferredCell: "notify",
      locked: true,
      float: false
    )
  ]

  FOR each builtin in builtinRules:
    IF no existing rule has rule.app == builtin.app:
      appRules.append(builtin)
```

Call this at end of `parseAppRules`.

### DW-3.1: Add helper to query locked cells

```
FUNCTION getLockedCellRules() -> [(bundleIDOrApp: String, cellID: String)]:
  result = []
  FOR rule in appRules:
    IF rule.locked AND rule.preferredCell is not nil/empty:
      result.append((rule.app, rule.preferredCell!))
  RETURN result
```

---

## Section 2: Assignment Changes — `GridAssignment.swift`

### New helper: get locked cell for a window

```
// DW-3.3: Check if a window matches a locked rule and return the locked cell ID
FUNCTION getLockedCell(appName, bundleID, appRules) -> String?:
  FOR rule in appRules:
    IF rule.locked
       AND rule.preferredCell is not nil/empty
       AND matchesAppRule(appName, bundleID, rule):
      RETURN rule.preferredCell
  RETURN nil
```

### New helper: collect all locked cell IDs (for exclusion)

```
// DW-3.2: Build set of cell IDs that are locked by any rule
FUNCTION lockedCellIDs(appRules) -> Set<String>:
  result = Set<String>()
  FOR rule in appRules:
    IF rule.locked AND rule.preferredCell is not nil/empty:
      result.insert(rule.preferredCell!)
  RETURN result
```

### Modify `assignWindows` — Phase 1 addition

Between Phase 1 (classify) and Phase 2 (strategy), add locked cell handling:

```
// DW-3.2, DW-3.3: Handle locked cells before strategy
// Phase 1.5: Pre-assign locked windows, filter locked cells from strategies

lockedCells = lockedCellIDs(appRules)
var tileableAfterLocked: [WindowState] = []

FOR window in tileable:
  appName = window.appName ?? ""
  bundleID = bundleIDLookup(window.pid)
  lockedCell = getLockedCell(appName, bundleID, appRules)

  IF lockedCell != nil AND result.assignments[lockedCell] != nil:
    // DW-3.3: Window matches a locked rule — assign directly
    result.assignments[lockedCell]!.append(window.id)
  ELSE:
    tileableAfterLocked.append(window)

// DW-3.5: Pass remaining (non-locked) windows to strategy as before
// Use tileableAfterLocked instead of tileable for all strategies
```

### Modify each strategy to skip locked cells — DW-3.2

Each strategy must not assign non-matching windows to locked cells.

**assignAutoFlow:**
```
// Filter sortedCells to exclude locked cell IDs
sortedCells = sortedCells.filter { !lockedCells.contains($0) }
```

Pass `lockedCells` as parameter.

**assignPinned:**
```
// In second pass (unpinned distribution), skip locked cells when finding empty/least-populated
emptyCells = filter out locked cells from empty cells
findLeastPopulatedCell: skip locked cells
```

Pass `lockedCells` as parameter.

**assignPreserve:**
```
// In second pass (auto-flow unassigned), skip locked cells
findLeastPopulatedCell: skip locked cells
```

Pass `lockedCells` as parameter.

**assignByPosition:**
```
// Skip locked cells when finding best overlap cell
// Skip locked cells in least-populated fallback
```

Pass `lockedCells` as parameter.

### Modify `findLeastPopulatedCell` (static, in GridAssignment)

```
// DW-3.2: Add optional excludeCells parameter
FUNCTION findLeastPopulatedCell(assignments, excludeCells: Set<String> = []) -> String:
  candidates = assignments.keys.filter { !excludeCells.contains($0) }
  RETURN candidates.sorted().min { a, b in
    (assignments[a]?.count ?? 0) < (assignments[b]?.count ?? 0)
  } ?? ""
```

---

## Section 3: Reconciler Changes — `GridReconciler.swift`

### DW-3.3: Check locked rule in `handleWindowCreated`

Before the least-populated-cell fallback, check if the new window matches a locked rule:

```
// After getting assignments and before findLeastPopulatedCell:

// Resolve bundleID for this window's PID
bundleID = stateManager.getState().applications[String(windowState.pid)]?.bundleIdentifier

// Check locked rules
IF let gridConfig:
  lockedCell = getLockedCell(appName, bundleID, gridConfig.appRules)
  IF lockedCell != nil:
    // Verify the cell exists in current assignments
    IF assignments[lockedCell] != nil:
      gridState.assignWindow(windowID, toCellID: lockedCell, inSpace: spaceID)
      syncBordersForCurrentSpace()
      log("reconcile.win.create.locked", data: ...)
      RETURN

// Also: skip locked cells in least-populated fallback
lockedCells = lockedCellIDs(gridConfig.appRules)
leastPopulatedCell = findLeastPopulatedCell(assignments, excluding: lockedCells)
```

NOTE: The reconciler's `findLeastPopulatedCell` is a private instance method (line 976). Modify it to accept an `excludeCells` parameter too, or use the static one from `GridAssignment`.

---

## Section 4: Tests — `GridAssignmentTests.swift`

### Test 1: Non-matching window skips locked cell

```
GIVEN:
  layout with cells ["left", "right", "notify"]
  appRules = [GridAppRule(app: "com.thegrid.notify", preferredCell: "notify", locked: true)]
  windows = [window1(appName: "Safari", pid: 1)]
  bundleIDLookup returns "com.apple.Safari" for pid 1

WHEN: assignWindows with strategy .autoFlow

THEN:
  assignments["notify"] is empty
  window1 assigned to "left" or "right" (not "notify")
```

### Test 2: Matching window auto-assigns to locked cell

```
GIVEN:
  layout with cells ["left", "right", "notify"]
  appRules = [GridAppRule(app: "com.thegrid.notify", preferredCell: "notify", locked: true)]
  windows = [window1(appName: "GridNotify", pid: 1)]
  bundleIDLookup returns "com.thegrid.notify" for pid 1

WHEN: assignWindows with strategy .autoFlow

THEN:
  assignments["notify"] == [window1.id]
```

### Test 3: Non-locked preferredCell still works (DW-3.5 regression)

```
GIVEN:
  layout with cells ["left", "right"]
  appRules = [GridAppRule(app: "com.apple.Safari", preferredCell: "right", locked: false)]
  windows = [window1(appName: "Safari", pid: 1), window2(appName: "Terminal", pid: 2)]
  bundleIDLookup returns "com.apple.Safari" for pid 1

WHEN: assignWindows with strategy .pinned

THEN:
  assignments["right"] contains window1.id
  assignments["left"] contains window2.id
  (same behavior as before — preferredCell without locked still works)
```
