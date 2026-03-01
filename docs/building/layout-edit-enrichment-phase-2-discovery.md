# Phase 2 Discovery: Wire enrichers into layoutEditCmd

## Insertion Point for Registry Init
**File:** `grid-cli/cmd/grid/main.go`, after line ~1582 (after `gridReconcile.Sync()`)

Insert before the cell-building if/else at line ~1590:
```go
registry := enrichers.NewRegistry()
registry.RefreshCaches()
process.RefreshProcessTree()
defer registry.Cleanup()
```

## WindowEntry Loop 1: --all mode (lines 1603-1616)
```go
for _, cellID := range sortedCellIDs {
    cellState := spaceState.Cells[cellID]
    cell := gridEdit.CellInfo{CellID: cellID}
    if cellState != nil {
        for _, wid := range cellState.Windows {
            entry := gridEdit.WindowEntry{WID: wid, AppName: "unknown"}
            if w := snap.GetWindowByID(wid); w != nil {
                entry.AppName = w.AppName
                entry.Title = w.Title
            }
            cell.Windows = append(cell.Windows, entry)
        }
    }
    cells = append(cells, cell)
}
```

## WindowEntry Loop 2: focused-cell mode (lines 1627-1634)
```go
for _, wid := range cellState.Windows {
    entry := gridEdit.WindowEntry{WID: wid, AppName: "unknown"}
    if w := snap.GetWindowByID(wid); w != nil {
        entry.AppName = w.AppName
        entry.Title = w.Title
    }
    cell.Windows = append(cell.Windows, entry)
}
```

## Enrichment Pattern (from picker at lines 2320-2402)
```go
registry := enrichers.NewRegistry()
registry.RefreshCaches()
process.RefreshProcessTree()

// per window:
if enrichResult := registry.Enrich(bundleID, w.PID, title); enrichResult != nil {
    if enrichResult.Title != "" {
        title = enrichResult.Title
    }
    // enrichResult.Subtitle available
}

registry.Cleanup()
```

## Key API
- `registry.Enrich(bundleID string, pid int, windowTitle string) *Result`
- `Result.Title`, `Result.Subtitle` — both strings
- `WindowInfo.BundleID` (string), `WindowInfo.PID` (int)
- `snap.GetWindowByID(wid uint32) *WindowInfo`

## Imports — already present
- `enrichers` at line 42
- `process` at line 41
