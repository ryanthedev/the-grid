# Pseudocode: Phase 3 - Per-display frame persistence

## Files to Create/Modify
- `grid-server/Sources/GridServer/Grid/GridTerminal.swift` (modify)

## Design: Frame Persistence

### Approaches Considered
1. **Inline persistence** -- save/restore logic directly in toggleTerminalWindow methods
2. **Dedicated methods** -- saveFrameForDisplay/restoreFrameForDisplay as separate private methods
3. **Separate FrameStore class** -- extract persistence into its own type

### Comparison
| Criterion | A (Inline) | B (Methods) | C (Class) |
|-----------|------------|-------------|-----------|
| Interface simplicity | Same toggle API | Same toggle API | Same toggle API |
| Information hiding | Mixes I/O with toggle | Hides I/O behind methods | Over-encapsulated |
| Caller ease of use | Same | Same | Same |
| Code readability | Toggle becomes long | Toggle stays focused | Extra indirection |

### Choice: B (Dedicated methods)
Toggle logic stays readable. File I/O details hidden behind saveFrameForDisplay/restoreFrameForDisplay. In-memory cache means disk reads happen once (lazy load).

### Depth Check
- Public interface methods: 0 new (toggle() unchanged)
- Hidden details: JSON encoding/decoding, file path, lazy loading, bounds checking
- Common case complexity: simple (save on hide, restore on show)

## Pseudocode

### GridTerminal.swift -- New Types and Properties

```
// Codable struct for persisting a terminal window frame
TerminalFrame struct (Codable):
    x: Double
    y: Double
    width: Double
    height: Double

// New instance properties on GridTerminal:
terminalFrames: dictionary mapping String (display UUID) to TerminalFrame
    -- initially nil to support lazy loading
terminalFramesLoaded: boolean, initially false
    -- tracks whether we've attempted to load from disk

// Computed property for file path
terminalFramePath: String
    -- returns XDG.stateHome + "/thegrid/terminal-frame.json"
```

### GridTerminal.swift -- loadTerminalFrames()

```
private function loadTerminalFrames:
    If terminalFramesLoaded is true, return early (already loaded)
    Set terminalFramesLoaded to true
    Initialize terminalFrames to empty dictionary

    Try to read data from file at terminalFramePath
    If file does not exist or read fails, return silently (empty dict is fine)

    Try to decode the data as dictionary of String to TerminalFrame using JSONDecoder
    If decode succeeds, set terminalFrames to the decoded value
    If decode fails, log a warning and keep empty dictionary
```

### GridTerminal.swift -- saveTerminalFrames()

```
private function saveTerminalFrames:
    Ensure terminalFrames is not nil (guard)

    Try to encode terminalFrames using JSONEncoder
    Set encoder output formatting to prettyPrinted for readability

    Try to write encoded data to file at terminalFramePath atomically
    If write fails, log a warning (non-fatal, frame just won't persist across restarts)
```

### GridTerminal.swift -- toggleTerminalWindow (modified hide path)

```
In the hide branch (isVisible && onActiveSpace):
    Before calling orderWindowOut:
        Load terminal frames lazily (call loadTerminalFrames)
        If we have an activeDisplayUUID from wmState.metadata:
            If we can get the window state for this windowID:
                Create a TerminalFrame from the window's current frame (x, y, width, height)
                Store it in terminalFrames keyed by activeDisplayUUID
                Save terminal frames to disk
    Then proceed with existing orderWindowOut call
    Log "term.hide" as before
```

### GridTerminal.swift -- toggleTerminalWindow (modified show path)

```
In the show branch (not visible or not on active space):
    After moving window to space (existing cross-space logic):
        Load terminal frames lazily (call loadTerminalFrames)
        Determine the active display UUID from wmState.metadata
        Get the target display from wmState.displays matching the UUID
        Get the display's visible frame (for bounds checking)

        If a saved frame exists for this display UUID:
            -- RESTORE mode: use saved x,y position only (preserve current window size)
            Extract saved x, y from the saved TerminalFrame

            -- Bounds check: verify saved position is within display's visible bounds
            Get the window's current size from wmState
            If saved x + window width exceeds display right edge, or
               saved y + window height exceeds display bottom edge, or
               saved x < display left edge, or
               saved y < display top edge:
                -- Position is out of bounds, fall through to center mode
                Use center mode instead
            Else:
                -- Position is valid, restore it
                Get AX element for the window
                Call setWindowPosition with the saved x, y
                Log "term.position" with mode "restore", x, y, displayUUID

        If no saved frame exists (or bounds check failed):
            -- CENTER mode: center at current window size with display offset
            Get window's current size from wmState
            Get display offset via await MainActor.run { gridConfig.getDisplayOffset(...) }
            Calculate centered x = displayOrigin.x + (displayWidth - windowWidth) / 2 + offsetX
            Calculate centered y = displayOrigin.y + (displayHeight - windowHeight) / 2 + offsetY
            Get AX element for the window
            Call setWindowPosition with calculated x, y
            Log "term.position" with mode "center", x, y, displayUUID

    Then proceed with existing orderWindowToFront, setWindowLayer, focusWindow calls
```

### GridTerminal.swift -- sizeAndCenterOnDisplay (no changes needed)
This method is only called from `launchTerminal()` for initial sizing of newly launched terminals. No frame persistence needed here -- first launch always sizes fresh.

## Design Notes

1. **Restore position only, not size**: The plan specifies restoring x,y only when a saved frame exists. This respects user manual resizing -- if they resize the terminal, it keeps that size but goes back to its remembered position on each display.

2. **Lazy loading**: `loadTerminalFrames()` is called on first hide or show, not at init. This avoids unnecessary disk I/O if the terminal feature is never used.

3. **terminalFramesLoaded flag vs optional**: Using a boolean flag rather than Optional<Dictionary> because we need to distinguish "never loaded" from "loaded but empty." An optional dict would conflate nil (not loaded) with empty (loaded, no entries), and we'd need to check both states.

4. **Bounds check strategy**: If the saved position would place the window partially or fully off-screen (display layout changed, resolution changed), we fall back to center mode. This is a simple rectangle containment check.

5. **Center mode uses display offset**: Matching the existing `sizeAndCenterOnDisplay` behavior which applies `gridConfig.getDisplayOffset()`. The show path's center mode should be consistent with launch centering.

6. **Save happens on hide only**: We save the frame when hiding (not on every move/resize). This captures the user's "last used position" on that display.

7. **The show path repositioning replaces the existing hardcoded centering**: Lines 127-136 currently center horizontally at `displayFrame.origin.y`. The new logic replaces this with either saved-position restore or proper center-with-offset.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (deep module analysis done)
- [x] Ready for implementation
