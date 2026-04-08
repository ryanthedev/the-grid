# Discovery: Phase 3 — Locked Cell Support in grid-server

## Current State

### App Rules System

**Config (YAML):** `GridAppRuleYAML` in `GridConfig.swift:70-76`
```swift
struct GridAppRuleYAML: Codable {
    var app: String
    var preferredCell: String?
    var layouts: [String]?
    var float: Bool?
    var preferredStackMode: String?
}
```

**Runtime:** `GridAppRule` in `GridConfig.swift:142-148`
```swift
struct GridAppRule: Sendable {
    var app: String          // app name or bundle ID
    var preferredCell: String?
    var layouts: [String]?
    var float: Bool
    var preferredStackMode: GridStackMode?
}
```

**Parsing:** `parseAppRules` at `GridConfig.swift:864-880` — decodes YAML array, maps to `GridAppRule`.

**Lookup:** `getAppRule(appName:bundleID:)` at `GridConfig.swift:457-464` — matches by app name or bundle ID.

**Matching:** `matchesAppRule` at `GridAssignment.swift:151-157` — checks `rule.app == appName || rule.app == bundleID`.

### Assignment Flow

There are TWO assignment paths:

1. **Full layout apply** (`GridApply.applyLayout`): Calls `GridAssignment.assignWindows()` with a strategy. The `pinned` strategy respects `preferredCell`. The `position` strategy (default) ignores app rules entirely — it assigns by window overlap. The `preserve` strategy also ignores app rules (preserves previous positions).

2. **Reconciler window creation** (`GridReconciler.handleWindowCreated`): Does NOT use app rules at all. Simply finds least-populated cell and assigns there. No bundleID lookup, no preferredCell check.

### Key Insight: Two Places Need Locked Cell Logic

- `GridAssignment.assignWindows` — all strategies must skip locked cells for non-matching windows, and auto-assign matching windows to locked cells.
- `GridReconciler.handleWindowCreated` — must check locked rules before falling back to least-populated cell.

### Existing preferredCell Behavior

Only used in `assignPinned` strategy:
1. First pass: windows with `preferredCell` go to that cell (if it exists in layout)
2. Second pass: unpinned windows go to empty cells, then least-populated

The `preferredCell` is NOT exclusive — other windows can still land in the same cell if it's least-populated.

### bundleID Resolution

- In `GridAssignment.assignWindows`: passed as `bundleIDLookup` closure — `wmState.applications[String(pid)]?.bundleIdentifier`
- In `GridReconciler.handleWindowCreated`: NOT available (no bundleID lookup)
- The `StateManager` holds `WMState` which has `applications: [String: ApplicationState]` keyed by PID string, where `ApplicationState` has `bundleIdentifier: String?`

### No Existing Tests for Assignment

There are no tests for `GridAssignment` or app rules currently. Existing tests cover `WindowState`, `DeepMerge`, `BorderRenderer`, `XDG`, `NotificationStore`.

### No Default App Rules

There are no built-in/default app rules. The `appRules` array starts empty and is only populated from user config YAML.

## Assumption Verification

1. **Existing app rules system can support locked flag without schema break** — CONFIRMED. Adding `locked: Bool?` to `GridAppRuleYAML` is backward-compatible (optional field, defaults to nil/false). Runtime `GridAppRule` gets `locked: Bool` defaulting to `false`.

2. **GridNotify's window is discoverable via CGWindowList** — Cannot verify in this context (requires running app), but the design only needs the app to be treated like any other window. The locked rule matches by bundleID, so as long as GridNotify appears in `WMState.applications` with `bundleIdentifier == "com.thegrid.notify"`, it works.

## Files to Modify

| File | Change |
|------|--------|
| `GridConfig.swift` | Add `locked: Bool?` to YAML struct, `locked: Bool` to runtime struct, parse it, add default rule for com.thegrid.notify |
| `GridAssignment.swift` | Add locked cell logic: skip locked cells for non-matching, auto-assign matching windows, new helper functions |
| `GridReconciler.swift` | Check locked rules in `handleWindowCreated` before least-populated fallback |
| `Tests/GridServerTests/GridAssignmentTests.swift` | New file: 2-3 tests for locked cell logic |
