# Review: Phase 3 - Per-display frame persistence

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (manual verification per plan)

### Section mapping:

1. **TerminalFrame struct (Codable)** -- Lines 5-10. Has x, y, width, height as Double. Matches pseudocode exactly.
2. **terminalFrames dict + terminalFramesLoaded flag** -- Lines 23-24. `[String: TerminalFrame]` initialized to empty dict (not nil). The pseudocode said "initially nil to support lazy loading" but the implementation uses an empty dict with a boolean flag, which the pseudocode design notes (point 3) explicitly chose: "Using a boolean flag rather than Optional<Dictionary>." This is consistent with the spec.
3. **terminalFramePath computed property** -- Lines 27-29. Returns `XDG.stateHome + "/thegrid/terminal-frame.json"`. Matches pseudocode.
4. **loadTerminalFrames()** -- Lines 242-258. Early return if loaded, sets flag, initializes empty dict, reads file, decodes JSON, logs warning on decode failure. Matches pseudocode exactly.
5. **saveTerminalFrames()** -- Lines 260-269. Encodes with prettyPrinted, writes atomically, logs warning on failure. Pseudocode specified a guard for nil terminalFrames, but since the property is a non-optional dict (initialized to `[:]`), no guard is needed. The encoding of an empty dict is harmless. Acceptable deviation.
6. **Hide path saves frame** -- Lines 132-144. Loads frames lazily, checks activeDisplayUUID, reads window frame, stores TerminalFrame, saves to disk. All before orderWindowOut (line 147). Matches pseudocode.
7. **Show path restore mode** -- Lines 158-196. Loads frames, looks up saved frame by display UUID, gets display visibleFrame with fallback to frame, checks bounds, restores x,y only via setWindowPosition, logs `term.position` with mode "restore". Matches pseudocode.
8. **Show path center mode** -- Lines 198-224. Falls through when no saved frame or bounds check fails (via `positioned` flag). Gets display offset via `await MainActor.run`, calculates centered position with offset, logs `term.position` with mode "center". Matches pseudocode.
9. **sizeAndCenterOnDisplay unchanged** -- Lines 310-341. Only called from launchTerminal. No modifications for frame persistence. Matches pseudocode note that no changes are needed here.
10. **term.position log events** -- Lines 188-193 (restore) and 218-223 (center). Both include mode, x, y, display UUID. Matches pseudocode.

## Dead Code
None found. All methods are reachable. No commented-out blocks, unused imports, or debug statements. Phase 1 and 2 code (findTmux, sizeAndCenterOnDisplay, launchTerminal, findTerminalWindow, matchesTerminalTitle) remains intact and functional.

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 9 pseudocode sections mapped to implementation (see above) |
| Concurrency | N/A | Plan notes: "Commands are serialized through router -- no race condition on frame save/read." No shared mutable state accessed from multiple threads. |
| Error Handling | PASS | File read failure: returns silently with empty dict (line 247-248). JSON decode failure: logs warning, keeps empty dict (lines 255-257). File write failure: logs warning, non-fatal (lines 266-268). All I/O failures gracefully degrade to "no persistence." |
| Resource Mgmt | PASS | No long-lived resources. FileManager.contents returns Data (autoreleased). Process in findTmux is waited on. Pipe read completes before return. |
| Boundaries | PASS | Empty frames dict: first toggle centers (no saved frame path). Missing display: `displayFrame` is nil, both restore and center paths safely skip via optional binding. Missing window in wmState: guarded by optional binding throughout. Bounds check (lines 176-180) verifies all four edges. |
| Security | N/A | No untrusted external input. Frame file is written and read by the same process. File path is not user-controlled. |

## Defensive Programming

**Crisis invariants checked:**
- No executable code in assertions: No assertions used; all checks use standard control flow (guard, if-let, optional binding).
- No empty catch blocks: The `catch` in `findTmux` (line 298-300) has a comment explaining fall-through to default. The load/save catches both log warnings. Acceptable.
- External input validated: The JSON file from disk is decoded inside a do/catch with a typed decoder (`[String: TerminalFrame].self`). Malformed data is caught and logged; the dict stays empty.
- Barricade pattern: Public interface is `toggle()` only. All persistence logic is private. Frame data validated (bounds check) before use.

**Silent failure check:**
- `loadTerminalFrames()` silently returns on missing file (line 247-248): Correct behavior -- no file means no saved frames.
- `saveTerminalFrames()` logs on failure (line 267): Non-fatal, appropriate.
- `setWindowPosition` return value discarded (lines 184, 214): Consistent with existing codebase pattern for AX calls throughout the file.

No critical defensive violations found.
