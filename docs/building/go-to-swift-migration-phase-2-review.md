# Review: Phase 2 - GridState Actor

## Verdict: FAIL

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions (date formatter helpers are reasonable internal details)
- [x] Test coverage verified (plan specifies manual verification: load/mutate/persist roundtrip)
- [x] Codable model structs with CodingKeys matching Go format
- [x] Custom stackMode encode/decode (nil <-> "")
- [x] Actor with debounced persistence
- [x] Space access (getSpace, getSpaceReadOnly, removeSpace)
- [x] Space ID migration
- [x] Layout cycling (cycle, previous, setCurrentLayout, getCurrentLayout)
- [x] Window assignment (assign, prepend, insert, remove, removeFromAllSpaces)
- [x] Window queries (getWindowCell, getCellWindows, getAllWindowIDs, getWindowAssignments, setWindowAssignments)
- [x] Focus tracking (setFocus, getFocusedWindow, getFocusedCell)
- [x] Cell stack mode (get/set)
- [x] Split ratios (get/set)
- [x] Column/row ratios (get/set)
- [x] Query helpers (hasState, summary)
- [x] Ratio utilities (equalRatios, normalizeRatios, adjustRatiosForCount)

**Deviation 1 (minor):** `prependWindow` does not set `cell.lastFocusedWid = windowID`. The pseudocode does not explicitly mention it either, but `assignWindow` and `insertWindow` both set `lastFocusedWid` to the windowID. This is an inconsistency -- the prepended window should be tracked as the last focused window.

## Dead Code
None found. All imports used (`Foundation`). No commented-out blocks, no debug statements, no unreachable code.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | FAIL | Atomic write bug (see Issue 1); missing `lastFocusedWid` in `prependWindow` (see Issue 2) |
| Concurrency | PASS | Swift actor isolation serializes all access. `saveTask` is created inside the actor. No shared mutable state escapes. `Task` in `markDirty` captures `self` safely within actor context. |
| Error Handling | PASS | `load()` catches decode errors and logs them, falls back to empty state. `persistNow()` catches write errors, logs, and sets `isDirty = true` for retry. Debounce cancellation caught silently (correct -- not an error). |
| Resource Mgmt | PASS | `saveTask` is cancelled before creating a new one (no leaked tasks). No file handles held open. `flush()` available for clean shutdown. |
| Boundaries | PASS | `equalRatios(0)` returns `[]`. `normalizeRatios([])` returns `[]`. `normalizeRatios` with zero sum returns equal ratios. `adjustRatiosForCount` handles shrink/grow/empty. `cycleLayout` with empty layouts returns current. Index clamping in `insertWindow`. `getFocusedWindow` clamps to valid range. |
| Security | N/A | No untrusted external input. State file is user-owned. Space IDs come from macOS APIs. |

## Defensive Programming
- **Empty catch blocks:** The `markDirty` Task catch block is empty but correct -- cancellation is the only expected error and it means a newer save supersedes this one. Not a violation.
- **Silent failures:** `load()` logs errors and continues with empty state -- appropriate robustness choice for a window manager.
- **External input validation:** State file is external data. Decoding uses `decodeIfPresent` with defaults for all fields -- graceful handling of missing/malformed fields. PASS.
- **Assertions:** No assertions used, none needed -- all paths have explicit error handling.
- **Error strategy consistency:** Logging + graceful degradation throughout. Consistent.

## Issues (if FAIL)

### 1. CRITICAL: Atomic write will always fail when state.json exists
- **File:** `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridState.swift:202`
- **Problem:** `FileManager.moveItem(atPath:toPath:)` throws if the destination file already exists. After loading an existing `state.json`, every `persistNow()` call will fail because `state.json` is already present. The error handler sets `isDirty = true` for retry, but retries also fail for the same reason. State will **never** persist after loading existing data.
- **Fix:** Add `try? fm.removeItem(atPath: statePath)` before `try fm.moveItem(atPath: tmpPath, toPath: statePath)`. Or use `_ = rename(tmpPath, statePath)` which atomically replaces on POSIX systems.
- **Note:** `PickerHistory.swift:201` has the same bug but is out of scope for this review.

### 2. MINOR: `prependWindow` missing `lastFocusedWid` update
- **File:** `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Grid/GridState.swift:369-370`
- **Problem:** `prependWindow` sets `lastFocusedIdx = 0` but does not set `lastFocusedWid = windowID`. Both `assignWindow` (line 350) and `insertWindow` (line 385) set `lastFocusedWid`. This means after prepending, `lastFocusedWid` will be stale (0 or the previous value), which breaks focus restoration in `removeWindow` and `setWindowAssignments`.
- **Fix:** Add `cell.lastFocusedWid = windowID` after line 369.
