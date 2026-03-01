# Phase 1 Discovery: Parse apps and populate BundleID in parseSnapshot

## Current State

### parseSnapshot (snapshot.go:265-312)
- Calls `parseWindows(raw, spaceID)` at line 296
- Never touches `raw["applications"]`

### parseSnapshotForSpace (snapshot.go:208-263)
- Also calls `parseWindows(raw, targetSpaceID)` at line 247
- Same issue

### parseWindows (snapshot.go:457-480)
- Signature: `func parseWindows(raw map[string]interface{}, spaceID string) []WindowInfo`
- Iterates raw windows, calls `parseWindow(w, spaceID)`

### parseWindow (snapshot.go:482-537)
- Line 515: `BundleID: toString(win["bundleId"])` — always empty since server doesn't include bundleId per window
- Line 527: `PID: int(toFloat64(win["pid"]))` — always populated

### Server dump format for applications
```json
{
  "applications": {
    "12345": {
      "pid": 12345,
      "bundleIdentifier": "com.mitchellh.ghostty",
      "localizedName": "Ghostty",
      ...
    }
  }
}
```
Key is PID as string, value has `bundleIdentifier` field.

## Required Changes

1. Add `parseAppBundleIDs(raw) map[int]string` helper
2. In `parseSnapshot`: call helper before parseWindows, pass map through
3. Update `parseWindows` signature to accept `appBundleIDs map[int]string`
4. Update `parseWindow` signature to accept `appBundleIDs map[int]string`
5. In `parseWindow`: after building WindowInfo, if BundleID is empty, look up from map
6. Same flow for `parseSnapshotForSpace`

## Call sites for parseWindows (2)
- `parseSnapshot` line 296
- `parseSnapshotForSpace` line 247

## Call sites for parseWindow (2, both inside parseWindows)
- line 465: `parseWindow(w, spaceID)`
- line 474: `parseWindow(w, spaceID)`
