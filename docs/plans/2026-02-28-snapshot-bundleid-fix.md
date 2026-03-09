# Plan: Populate WindowInfo.BundleID from applications in parseSnapshot

**Created:** 2026-02-28
**Status:** complete

## Context

`WindowInfo.BundleID` is always empty because the server's window dict doesn't include `bundleId`. However, the dump response includes an `applications` map (keyed by PID as string) with `bundleIdentifier` per app. `parseSnapshot` discards this data. The picker works around this by doing a second full JSON parse via `models.ParseState()` just to call `FindApplicationByPID()`.

## Chosen Approach

Parse the `applications` section during `parseSnapshot` into a `map[int]string` (PID→BundleID), then look up each window's PID to populate `WindowInfo.BundleID`. Zero extra latency — the data is already in the raw dump.

## Implementation Checklist

### Phase 1: Parse apps and populate BundleID in parseSnapshot

- [ ] Add helper `parseAppBundleIDs(raw) map[int]string` in `snapshot.go` that extracts PID→BundleID from `raw["applications"]`
- [ ] Call it in `parseSnapshot()` before `parseWindows()`
- [ ] Pass the map to `parseWindows()` and `parseWindow()` so each `WindowInfo.BundleID` is set from the app lookup (falling back to `win["bundleId"]` if present)
- [ ] Same for `parseSnapshotForSpace()`

**Files:** `grid-cli/internal/server/snapshot.go`

**Details:**
```
applications map in dump: { "12345": { "bundleIdentifier": "com.mitchellh.ghostty", "pid": 12345, ... }, ... }
→ map[int]string{ 12345: "com.mitchellh.ghostty" }
→ WindowInfo.BundleID = appBundleIDs[window.PID]
```

### Phase 2: Remove w.BundleID workaround from layoutEditCmd

- [ ] In `layoutEditCmd` (main.go), the enricher call `registry.Enrich(w.BundleID, w.PID, w.Title)` should now work as-is since `w.BundleID` is populated
- [ ] Verify no code changes needed in layoutEditCmd — the Phase 1 fix makes it work

**Files:** None (verification only)

## Test Plan

- [ ] Add `TestParseAppBundleIDs` unit test
- [ ] `go test ./internal/server/...`
- [ ] `go build ./cmd/grid/`
- [ ] Manual: `EDITOR=cat thegrid layout edit --all` shows enriched tmux info

## Notes

- `parseSnapshotForSpace()` also needs the same fix (shares `parseWindows`)
- The `win["bundleId"]` fallback in `parseWindow` can stay as a no-op safety net
- This fix benefits ALL Snapshot consumers, not just layoutEditCmd
