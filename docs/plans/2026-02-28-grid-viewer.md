# Plan: GridViewer - Native Swift Media Viewer

**Created:** 2026-02-28
**Status:** in-progress

## Context

theGrid has no built-in media viewer. The `record --open` flag uses `exec.Command("open", ...)` which delegates to whatever macOS app handles the file type. A native viewer gives consistent, keyboard-driven previewing of images, GIFs, and video - especially useful for reviewing `thegrid record` output.

## Constraints

- Zero external dependencies (like GridPicker)
- Single `main.swift` file (project convention)
- macOS 13+ target
- Chromeless, borderless, keyboard-only controls
- Single-instance with file reuse (PID + socket)
- ~520 lines estimated

## Chosen Approach

**CGImageSource + DispatchSourceTimer for GIF animation, Unix socket for single-instance reuse.**

Rationale: GIF frame stepping (Left/Right) and pause/play (Space) are valuable for reviewing recordings. DispatchSourceTimer avoids CVDisplayLink deprecation issues. Socket-based reuse follows the proven GridPicker pattern and is more robust than pasteboard signaling.

### Renderer Matrix

| Content | Renderer | Detection |
|---------|----------|-----------|
| Static images (PNG, JPEG, WebP, HEIC) | `NSImageView` | UTType conforms to `.image` and not GIF |
| Animated GIFs | `CGImageSource` frame extraction + `DispatchSourceTimer` + `NSImageView` | UTType conforms to `.gif` |
| Video (MP4, MOV) | `AVPlayerLayer` (chromeless) | UTType conforms to `.movie` |

**Note:** WebM requires macOS 14+. On macOS 13, fall back to system `open` with a warning.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| ESC / Q | Close window and quit |
| Space | Pause/play (video and GIF) |
| Left arrow | Step backward (video: -5s, GIF: -1 frame) |
| Right arrow | Step forward (video: +5s, GIF: +1 frame) |

### Window Behavior

- Borderless, floating, shadow, no title bar
- Sized to media dimensions, capped at 90% of screen
- Centered on active screen
- Dark semi-transparent background for letterboxing
- Level: `.floating`
- Collection behavior: `[.canJoinAllSpaces, .transient]`

### Single-Instance Protocol

1. On launch: check PID file (`~/.local/state/thegrid/grid-viewer.pid`)
2. If PID alive: connect to socket (`~/.local/state/thegrid/grid-viewer.sock`), send file path as newline-terminated string, exit
3. If PID dead or no PID: write PID file, start socket listener, show window

## Implementation Checklist

### Phase 1: Static Image Viewer (~200 lines)

- [ ] Add `GridViewer` target to `grid-server/Package.swift` (zero deps)
- [ ] Create `grid-server/Sources/GridViewer/main.swift` with logging boilerplate (copy from GridTerminal)
- [ ] Implement `ContentType` enum and `detectContentType(from:)` using `UTType`
- [ ] Implement `fitWindowToContent(mediaSize:, screen:)` sizing function
- [ ] Create `ViewerWindow: NSWindow` subclass (borderless, floating, shadow)
- [ ] Create `ImageContentView` using `NSImageView` for static images
- [ ] Implement keyboard handling (ESC/Q to close)
- [ ] Implement PID file management (write on start, delete on exit)
- [ ] Wire up `AppDelegate` and procedural main entry point
- [ ] Add `grid-viewer` target to Makefile

**Files:** `grid-server/Package.swift`, `grid-server/Sources/GridViewer/main.swift`, `Makefile`

**Verify:** `make viewer && .build/debug/grid-viewer ~/some-image.png` shows image in centered borderless window, ESC closes it.

### Phase 2: Video Playback (+80 lines)

- [ ] Create `VideoContentView` with `AVPlayerLayer` (no controls)
- [ ] Implement Space for play/pause, Left/Right for seek ±5s
- [ ] Wire content type detection to swap between ImageContentView and VideoContentView
- [ ] Auto-play on load, loop video

**Files:** `grid-server/Sources/GridViewer/main.swift`

**Verify:** `grid-viewer recording.mp4` plays video, Space pauses, arrows seek, ESC closes.

### Phase 3: Animated GIF (+120 lines)

- [ ] Create `GIFContentView` with `CGImageSource` frame extraction
- [ ] Implement `gifFrameDelay(source:index:)` to read per-frame delay from GIF properties
- [ ] Animate with `DispatchSourceTimer`, cycling frames on `NSImageView`
- [ ] Implement Space for pause/play, Left/Right for frame stepping
- [ ] Handle GIF loop count (default infinite)
- [ ] Pre-render all frames to `[NSImage]` array on load for correct disposal

**Files:** `grid-server/Sources/GridViewer/main.swift`

**Verify:** `grid-viewer animation.gif` animates, Space pauses, arrows step frames, ESC closes.

### Phase 4: Single-Instance Reuse (+100 lines)

- [ ] Implement `ViewerSocket` class (Unix domain socket listener, simplified from GridPicker)
- [ ] On launch: check existing PID, connect to socket, send path, exit
- [ ] On receive: load new file, resize window, bring to front with `NSApp.activate()`
- [ ] Clean up socket file on exit (signal handlers for SIGTERM/SIGINT)

**Files:** `grid-server/Sources/GridViewer/main.swift`

**Verify:** Launch `grid-viewer image1.png`, then `grid-viewer image2.png` - second invocation reuses existing window.

### Phase 5: CLI Integration (+50 lines Go)

- [ ] Add `findViewerExecutable(overridePath)` function (modeled on `findPickerExecutable` at line 2156)
- [ ] Add `viewCmd` cobra command: `thegrid view <file>` — resolves absolute path, finds binary, launches/sends
- [ ] Register `viewCmd` in `init()` and add to `shouldSkipMutex` skipExact map
- [ ] Update `record --open` (line 4578) to prefer GridViewer, fall back to system `open`
- [ ] Add `viewer` build target to Makefile, add to `dev`/`install-dev` dependencies

**Files:** `grid-cli/cmd/grid/main.go`, `Makefile`

**Verify:** `thegrid view image.png` opens viewer. `thegrid record --open` opens recording in viewer.

## Test Coverage

**Level:** Per-phase manual verification

## Test Plan

- [ ] Phase 1: View PNG, JPEG, WebP, HEIC — all display correctly, sized to content
- [ ] Phase 2: View MP4, MOV — plays, pauses with Space, seeks with arrows
- [ ] Phase 3: View animated GIF — animates, pauses with Space, steps with arrows
- [ ] Phase 4: Second invocation reuses window, file swaps correctly
- [ ] Phase 5: `thegrid view` command works, `record --open` uses viewer

## Notes

- WebM playback only works on macOS 14+. On 13, log warning and fall back to `open`.
- Large GIFs (100+ MB) could cause memory pressure from pre-rendering all frames. For V1, accept this limitation. Can add lazy loading later if needed.
- GIF frame disposal: pre-rendering all frames into `NSImage` array handles disposal correctly since each frame is a complete composited image.
- Window activation: use `NSApp.setActivationPolicy(.regular)` before `activate(ignoringOtherApps: true)`, same as GridPicker.

## Key Reference Files

- `grid-server/Sources/GridTerminal/main.swift` — PID file, signal handling, chromeless window pattern
- `grid-server/Sources/GridPicker/main.swift` — Unix socket listener (lines 1605-1752), daemon PID management
- `grid-cli/cmd/grid/main.go:2156` — `findPickerExecutable()` pattern to copy
- `grid-cli/cmd/grid/main.go:4578` — `record --open` to update
- `grid-cli/cmd/grid/main.go:5160` — `skipExact` map to add `thegrid view`

## Execution Log

_Filled during /code-foundations:building_
