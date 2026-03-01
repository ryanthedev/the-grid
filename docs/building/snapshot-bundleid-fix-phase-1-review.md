# Phase 1 Review: BundleID fallback from applications map

**Date**: 2026-02-28
**File reviewed**: `grid-cli/internal/server/snapshot.go`
**Plan**: `docs/building/snapshot-bundleid-fix-phase-1-pseudocode.md`

## Result: PASS

All seven verification criteria satisfied.

---

## Checklist

### 1. `parseAppBundleIDs` exists and is correct

**PASS** -- Lines 459-480.

- Iterates `raw["applications"]` as `map[string]interface{}`
- Extracts `bundleIdentifier` (via `toString`) and `pid` (via `toFloat64` cast to `int`)
- Skips entries where bundleID is empty or pid is 0
- Returns `map[int]string` (pid -> bundleID)
- Gracefully returns empty map if `"applications"` key is missing or wrong type

### 2. `parseWindows` signature includes `appBundleIDs` and passes it through

**PASS** -- Line 482: `func parseWindows(raw map[string]interface{}, spaceID string, appBundleIDs map[int]string) []WindowInfo`

Both call sites pass `appBundleIDs` to `parseWindow`:
- Line 490 (array branch): `parseWindow(w, spaceID, appBundleIDs)`
- Line 499 (map branch): `parseWindow(w, spaceID, appBundleIDs)`

### 3. `parseWindow` signature includes `appBundleIDs` with fallback logic

**PASS** -- Line 507: `func parseWindow(w interface{}, spaceID string, appBundleIDs map[int]string) *WindowInfo`

Fallback at lines 557-561:
```go
if window.BundleID == "" && window.PID != 0 {
    if bid, ok := appBundleIDs[window.PID]; ok {
        window.BundleID = bid
    }
}
```

Correctly placed after the struct literal (which sets BundleID and PID) and before frame parsing. Only triggers when the per-window `bundleId` field was empty.

### 4. `parseSnapshot` calls `parseAppBundleIDs` and passes to `parseWindows`

**PASS** -- Lines 297-298:
```go
appBundleIDs := parseAppBundleIDs(raw)
snap.Windows = parseWindows(raw, snap.SpaceID, appBundleIDs)
```

### 5. `parseSnapshotForSpace` does the same

**PASS** -- Lines 250-251:
```go
appBundleIDs := parseAppBundleIDs(raw)
snap.Windows = parseWindows(raw, targetSpaceID, appBundleIDs)
```

### 6. No other functions broken

**PASS** -- Searched entire `grid-cli/` tree:

- `parseWindows(` appears exactly 3 times: definition + 2 callers (both updated)
- `parseWindow(` appears exactly 3 times: definition + 2 callers (both updated)
- `parseAppBundleIDs(` appears exactly 3 times: definition + 2 callers
- No test files reference any of these internal functions

All callers use the new 3-argument signatures. No stale call sites.

### 7. Build and tests pass

**PASS**
```
$ go build ./cmd/grid/          # exit 0, no errors
$ go test ./internal/server/... # ok (cached)
```
