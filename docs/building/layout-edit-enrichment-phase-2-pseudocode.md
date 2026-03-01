# Phase 2 Pseudocode: Wire enrichers into layoutEditCmd

## 1. Registry initialization (insert at line 1583, after `gridReconcile.Sync` block, before line 1584)

### Before (lines 1582-1584):
```go
		}

		spaceState := runtimeState.GetSpaceReadOnly(snap.SpaceID)
```

### After:
```go
		}

		// Initialize enrichers for window title enrichment
		registry := enrichers.NewRegistry()
		registry.RefreshCaches()
		process.RefreshProcessTree()
		defer registry.Cleanup()

		spaceState := runtimeState.GetSpaceReadOnly(snap.SpaceID)
```

## 2. Loop 1: --all mode (lines 1607-1614)

### Before (lines 1607-1614):
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

### After:
```go
				for _, wid := range cellState.Windows {
					entry := gridEdit.WindowEntry{WID: wid, AppName: "unknown"}
					if w := snap.GetWindowByID(wid); w != nil {
						entry.AppName = w.AppName
						entry.Title = w.Title
						if enrichResult := registry.Enrich(w.BundleID, w.PID, w.Title); enrichResult != nil {
							if enrichResult.Title != "" {
								entry.Title = enrichResult.Title
							}
							if enrichResult.Subtitle != "" {
								entry.Subtitle = enrichResult.Subtitle
							}
						}
					}
					cell.Windows = append(cell.Windows, entry)
				}
```

## 3. Loop 2: focused-cell mode (lines 1627-1634)

### Before (lines 1627-1634):
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

### After:
```go
			for _, wid := range cellState.Windows {
				entry := gridEdit.WindowEntry{WID: wid, AppName: "unknown"}
				if w := snap.GetWindowByID(wid); w != nil {
					entry.AppName = w.AppName
					entry.Title = w.Title
					if enrichResult := registry.Enrich(w.BundleID, w.PID, w.Title); enrichResult != nil {
						if enrichResult.Title != "" {
							entry.Title = enrichResult.Title
						}
						if enrichResult.Subtitle != "" {
							entry.Subtitle = enrichResult.Subtitle
						}
					}
				}
				cell.Windows = append(cell.Windows, entry)
			}
```

## Notes

- `WindowInfo` fields used: `w.BundleID` (string), `w.PID` (int), `w.Title` (string)
- `WindowEntry.Subtitle` field already exists (added in Phase 1)
- `enrichers` and `process` imports already present in main.go (lines 41-42)
- `defer registry.Cleanup()` placed before any early-return paths that follow (the `spaceState == nil` check at line 1585 could return before enrichers are used, but cleanup of an unused registry is harmless)
- The enrichment block is identical in both loops; could be extracted to a helper, but inline keeps the diff minimal
