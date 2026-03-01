# Phase 1 Pseudocode: BundleID fallback from applications map

Target file: `grid-cli/internal/server/snapshot.go`

---

## 1. New helper function `parseAppBundleIDs` (insert after line 455)

```
// BEFORE: (nothing — new function)

// AFTER:
func parseAppBundleIDs(raw map[string]interface{}) map[int]string {
    result := make(map[int]string)

    apps, ok := raw["applications"].(map[string]interface{})
    if !ok {
        return result
    }

    for _, v := range apps {
        app, ok := v.(map[string]interface{})
        if !ok {
            continue
        }
        bundleID := toString(app["bundleIdentifier"])
        pid := int(toFloat64(app["pid"]))
        if bundleID != "" && pid != 0 {
            result[pid] = bundleID
        }
    }

    return result
}
```

---

## 2. Update `parseWindows` signature (line 457)

```
// BEFORE (line 457):
func parseWindows(raw map[string]interface{}, spaceID string) []WindowInfo {

// AFTER:
func parseWindows(raw map[string]interface{}, spaceID string, appBundleIDs map[int]string) []WindowInfo {
```

Pass `appBundleIDs` through to both `parseWindow` call sites:

```
// BEFORE (line 465):
                if win := parseWindow(w, spaceID); win != nil {

// AFTER:
                if win := parseWindow(w, spaceID, appBundleIDs); win != nil {
```

```
// BEFORE (line 474):
        if win := parseWindow(w, spaceID); win != nil {

// AFTER:
        if win := parseWindow(w, spaceID, appBundleIDs); win != nil {
```

---

## 3. Update `parseWindow` signature and add fallback (line 482, after line 529)

Signature change:

```
// BEFORE (line 482):
func parseWindow(w interface{}, spaceID string) *WindowInfo {

// AFTER:
func parseWindow(w interface{}, spaceID string, appBundleIDs map[int]string) *WindowInfo {
```

Fallback lookup — insert after `DisplayUUID` assignment (after line 529), before frame parsing:

```
// BEFORE (lines 529-532):
        DisplayUUID:         toString(win["displayUUID"]),
    }

    // Parse frame

// AFTER:
        DisplayUUID:         toString(win["displayUUID"]),
    }

    // Fallback: populate BundleID from applications map if per-window field was empty
    if window.BundleID == "" && window.PID != 0 {
        if bid, ok := appBundleIDs[window.PID]; ok {
            window.BundleID = bid
        }
    }

    // Parse frame
```

---

## 4. Update `parseSnapshot` (line 296)

```
// BEFORE (line 296):
    snap.Windows = parseWindows(raw, snap.SpaceID)

// AFTER:
    appBundleIDs := parseAppBundleIDs(raw)
    snap.Windows = parseWindows(raw, snap.SpaceID, appBundleIDs)
```

---

## 5. Update `parseSnapshotForSpace` (line 250)

```
// BEFORE (line 250):
    snap.Windows = parseWindows(raw, targetSpaceID)

// AFTER:
    appBundleIDs := parseAppBundleIDs(raw)
    snap.Windows = parseWindows(raw, targetSpaceID, appBundleIDs)
```

---

## Summary of all touched lines

| Change | Location | Type |
|--------|----------|------|
| New `parseAppBundleIDs` function | After line 455 | Insert |
| `parseWindows` signature | Line 457 | Modify |
| `parseWindow` call (array branch) | Line 465 | Modify |
| `parseWindow` call (map branch) | Line 474 | Modify |
| `parseWindow` signature | Line 482 | Modify |
| BundleID fallback lookup | After line 529 | Insert |
| `parseSnapshot` caller | Line 296 | Modify |
| `parseSnapshotForSpace` caller | Line 250 | Modify |
