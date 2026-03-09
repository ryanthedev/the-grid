# Discovery: Phase 2 - GridState Actor

## Files Found

### Go source files (port from)
- `grid-cli/internal/state/state.go` (411 lines) — `RuntimeState`, `SpaceState`, `CellState` structs, `MigrateSpaceIDs`, window assignment/removal, focus tracking, layout cycling
- `grid-cli/internal/state/queries.go` (303 lines) — Read-only queries (`GetAllWindowIDs`, `GetCellWindows`, `GetCellSplitRatios`, etc.), `SetWindowAssignments` with ratio adjustment, `adjustRatiosForCount`, `normalizeRatios`
- `grid-cli/internal/state/persistence.go` (126 lines) — Load/save state.json, atomic writes via temp+rename, version migration stub

### Swift Phase 1 output (dependencies)
- `grid-server/Sources/GridServer/Grid/GridTypes.swift` — `GridDirection`, `GridStackMode`, `GridTrackType`, `GridTrackSize`, `GridCellDef`, `GridLayoutDef`, `GridAssignmentStrategy`
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` — `GridConfig` with `spaces: [String: GridSpaceConfig]`, `getSpaceConfig(spaceID:)`, `getLayout(id:)`, `getLayoutIDs()`

### Existing server state infrastructure
- `grid-server/Sources/GridServer/StateManager.swift` — OS-level window state (unrelated to grid state; different purpose)
- No existing `GridState.swift` — needs to be created from scratch

### Actual state.json on disk
- Path: `~/.local/state/thegrid/state.json`
- Format confirmed: matches Go struct exactly (version 1, spaces keyed by space ID string, displaySpaces keyed by display UUID, lastUpdated as ISO 8601 string)

## Current State

Phase 1 is complete. `GridTypes.swift` provides `GridStackMode` (used by `CellState.stackMode`). `GridConfig.swift` provides `GridSpaceConfig` with `layouts: [String]`, `defaultLayout: String`, and `autoApply: Bool` — needed for layout cycling and space config integration.

No grid-level state actor exists in the server. The server currently has `StateManager` for OS window tracking but nothing for cell assignments, focus, ratios, or layout selection.

## Go State.json Format (for migration compatibility)

```json
{
  "version": 1,
  "spaces": {
    "<spaceID>": {
      "spaceId": "<spaceID>",
      "currentLayoutId": "<layoutID>",
      "layoutIndex": 0,
      "cells": {
        "<cellID>": {
          "cellId": "<cellID>",
          "windows": [1041, 11972],
          "splitRatios": [0.5, 0.5],
          "stackMode": "",
          "lastFocusedIdx": 0,
          "lastFocusedWid": 0,
          "prevFocusedWid": 0
        }
      },
      "focusedCell": "middle",
      "focusedWindow": 0,
      "columnRatios": [0.3, 0.4, 0.3],
      "rowRatios": [1.0]
    }
  },
  "displaySpaces": {
    "<displayUUID>": ["<spaceID1>", "<spaceID2>"]
  },
  "lastUpdated": "2026-03-07T03:27:15.235438-06:00"
}
```

Key observations:
- `stackMode` is a string (empty string = no override, "vertical"/"horizontal"/"tabs")
- `windows` uses `uint32` window IDs
- `columnRatios`/`rowRatios` are optional (omitted when nil)
- `lastUpdated` is ISO 8601 with timezone
- Space IDs are numeric strings (macOS space identifiers)
- `displaySpaces` maps display UUIDs to ordered lists of space IDs

## Gaps

1. **No gaps in dependencies** — Phase 1 types and config are fully implemented and available.
2. **Thread safety model change** — Go uses `sync.RWMutex`; Swift uses actor isolation. The actor approach is simpler and eliminates the manual lock/unlock pattern entirely.
3. **Persistence model change** — Go saves synchronously on every command. Plan specifies debounced persistence (write at most every N seconds). This is a design improvement, not a compatibility issue.
4. **JSON CodingKeys needed** — Go uses `json:"spaceId"` (camelCase). Swift's default Codable uses camelCase too, but we need explicit CodingKeys to match Go's exact field names (e.g., `lastFocusedWid` not `lastFocusedWID`, `prevFocusedWid` not `prevFocusedWID`).
5. **Empty string vs nil for stackMode** — Go marshals empty string as `""`. Swift `GridStackMode?` would marshal as null. Need a custom coding strategy to match Go format (encode nil as `""`).

## Prerequisites

- [x] Phase 1 complete (GridTypes.swift, GridConfig.swift exist)
- [x] GridStackMode enum available
- [x] GridSpaceConfig with layouts/defaultLayout available
- [x] GridConfig.getSpaceConfig(spaceID:) available
- [x] State.json format documented from live data
- [x] All Go source code reviewed

## Recommendation

**BUILD** — All prerequisites are met. Create `Grid/GridState.swift` as a Swift actor that:
1. Matches Go's state.json format for read/write compatibility
2. Replaces mutex with actor isolation
3. Adds debounced persistence
4. Ports MigrateSpaceIDs, layout cycling, and all state mutation/query methods
