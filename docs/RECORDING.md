# Recording Feature

A comprehensive reference for screen recording with theGrid.

---

## 1. Overview

The `thegrid record` command captures screen regions as GIF, MP4, WebM, or MOV files. It integrates with theGrid's layout system to record specific cells, windows, or entire displays.

### Core Features

- **Toggle recording** — start with a command, stop with ctrl-c or same hotkey
- Record layout cells, windows, screens, or all displays
- Multiple output formats (GIF, MP4, WebM, MOV)
- Focus-following mode that crops to tracked cells
- Multi-monitor stitching for "all displays" captures
- Automatic file naming and output directory configuration
- Quality presets and customizable encoding settings

### Dependencies

- **screencapture** (built-in macOS tool) - Required for all recordings
- **ffmpeg** - Required for GIF/MP4/WebM conversion, multi-monitor stitching, and follow mode
  - Install: `brew install ffmpeg`
  - Falls back to MOV format if not available

---

## 2. Quick Start

### Basic Examples

```bash
# Record focused cell — press ctrl-c to stop
thegrid record

# Record for a fixed duration (5 seconds)
thegrid record -d 5

# Record specific cell
thegrid record cell main -d 10

# Record focused window as MP4
thegrid record window -f mp4

# Record current display
thegrid record screen

# Record all monitors stitched together
thegrid record all -f mp4

# Record with focus-following (crop follows focused cell)
thegrid record --follow
```

### Toggle Mode (Default)

When `--duration` is omitted, recording starts immediately and runs until stopped:

**CLI:**
```bash
# Start recording, press ctrl-c when done
thegrid record
thegrid record cell main -f mp4
thegrid record screen --cursor
```

**BFD hotkey:**
```
# Press once to start, press again to stop
@record toggle cell --open
@record toggle screen -f mp4
```

**Other stop methods:**
```bash
# From another terminal or BFD hotkey
@record stop
thegrid record stop   # (via RPC: grid.record.stop)
```

### Common Workflows

```bash
# High-quality MP4 demo video (toggle — stop when done)
thegrid record cell editor -f mp4 -q high -w 1920

# Quick GIF for sharing (fixed 5 seconds)
thegrid record window -d 5 --countdown 2 --open

# Full screen recording with cursor (toggle)
thegrid record screen -f mp4 --cursor

# Follow-focus tutorial recording (toggle)
thegrid record --follow -f mp4 --cursor --open
```

---

## 3. Target Types

The first argument specifies what to record.

### Cell (default)

Records a layout cell's pixel bounds.

```bash
thegrid record                    # Focused cell
thegrid record cell              # Focused cell (explicit)
thegrid record cell main         # Specific cell by ID
```

**Requirements:**
- Active layout must be applied
- Cell must exist in current layout
- If no cell ID provided, uses focused cell

**Resolution:**
1. Loads current space state and active layout
2. Calculates cell pixel bounds using `reconcile.CalculateCellBounds`
3. Records the cell's exact screen region

### Window

Records a window's frame bounds.

```bash
thegrid record window            # Focused window
thegrid record window 12345      # Specific window by ID
```

**Requirements:**
- Window must exist and be visible
- If no window ID provided, uses focused window

**Resolution:**
1. Fetches window list from grid-server
2. Gets window frame (includes title bar and borders)
3. Records window's screen region

### Screen

Records an entire display.

```bash
thegrid record screen            # Current display
thegrid record screen 1          # Display 1 (main display)
thegrid record screen 2          # Display 2
```

**Requirements:**
- At least one display must be connected
- Display numbers are 1-based (1 = main/first display)

**Resolution:**
1. If no display number: uses current display (where focused window resides)
2. If display number: uses specified display from AllDisplays array
3. Records full display frame

### All Displays

Records all connected displays and stitches them into a single video.

```bash
thegrid record all
```

**Requirements:**
- ffmpeg must be installed
- At least one display connected

**How it works:**
1. Captures each display in parallel
2. Computes bounding box of all display frames
3. Creates black canvas sized to bounding box
4. Overlays each capture at its real screen coordinates
5. Result matches physical monitor arrangement

**Example:** Two monitors (1920x1080 and 2560x1440) arranged horizontally create a ~4480x1440 video with each monitor at correct position.

---

## 4. Flags Reference

### Duration

How long to record. When omitted, recording runs indefinitely until stopped.

```bash
-d, --duration <seconds>
```

- Default: **indefinite** (toggle mode — press ctrl-c or use `@record stop` to finish)
- Pass `-d <seconds>` for fixed-duration recording
- Range: Any positive integer
- Example: `-d 10` records for 10 seconds

### Output Path

Where to save the recording.

```bash
-o, --output <path>
```

- Default: Auto-generated filename
- Auto-generated format: `recording-<label>-<timestamp>.<format>`
  - `<label>`: target type + ID (e.g., "cell-main", "window-12345", "screen-1", "all")
  - `<timestamp>`: `YYYYMMDD-HHMMSS`
- If `recording.outputDir` config is set, file is saved there
- Example: `-o ~/Desktop/demo.mp4`

### Format

Output file format.

```bash
-f, --format <format>
```

- Default: `gif`
- Options: `gif`, `mp4`, `webm`, `mov`
- Requires ffmpeg for `gif`, `mp4`, `webm`
- MOV is native format from screencapture (no conversion)

**Format characteristics:**

| Format | Use case | Codec | Audio | Size |
|--------|----------|-------|-------|------|
| `gif` | Sharing, docs | Palette-based | None | Moderate |
| `mp4` | General video | H.264 (libx264) | None | Small |
| `webm` | Web embedding | VP9 (libvpx-vp9) | None | Smallest |
| `mov` | Native, editing | H.264 | None | Large |

### FPS

Frames per second for output.

```bash
--fps <number>
```

- Default: `0` (auto: 10 for GIF, 30 for video)
- Range: Typically 10-60
- Lower FPS = smaller file size
- Example: `--fps 15`

### Width

Maximum output width (preserves aspect ratio).

```bash
-w, --width <pixels>
```

- Default: `0` (no scaling, original resolution)
- Scales down if source is wider
- Height computed automatically to preserve aspect ratio
- Example: `-w 1920` caps width at 1920px

### Quality

Encoding quality preset.

```bash
-q, --quality <preset>
```

- Default: `medium`
- Options: `low`, `medium`, `high`

**Quality mappings:**

| Preset | GIF dither | MP4 CRF | WebM CRF |
|--------|------------|---------|----------|
| `low` | none | 28 | 40 |
| `medium` | bayer:bayer_scale=5 | 23 | 31 |
| `high` | sierra2_4a | 18 | 24 |

- Lower CRF = higher quality (18 is near-lossless)
- GIF dithering affects color gradients

### Countdown

Seconds to wait before recording starts.

```bash
--countdown <seconds>
```

- Default: `3`
- Range: 0+ (0 = skip countdown)
- Displays countdown in terminal before capture begins
- Example: `--countdown 5`

### Cursor

Include cursor in recording.

```bash
--cursor
```

- Default: `false` (cursor hidden)
- When enabled, system cursor is captured
- Useful for demonstrations and tutorials

### Open

Automatically open the recording when finished.

```bash
--open
```

- Default: `false`
- Uses macOS `open` command
- Opens with default application for file type
- Useful for quick preview

### Follow Mode

Crop follows focused cell during recording.

```bash
--follow
```

- Default: `false`
- Requires ffmpeg
- Overrides target to current screen
- Polls focus state every 100ms
- Creates dynamic crop filter from focus events

**How it works:**
1. Records full current display
2. Tracks focused cell changes in parallel
3. Builds ffmpeg crop filter from focus timeline
4. Applies filter to crop and scale to each focused cell
5. Concatenates segments for seamless transitions

**Requirements:**
- ffmpeg must be installed
- Active layout must be applied
- Cell focus changes are persisted to state

**Output dimensions:**
- Width and height are maximum across all focused cells
- Smaller cells are scaled up to match
- Ensures consistent video dimensions

**Example workflow:**
```bash
# Start recording with follow mode
thegrid record --follow -d 20 -f mp4 --cursor --open

# While recording, switch focus between cells:
thegrid focus left
thegrid focus right
thegrid focus main

# Video shows cropped view following each cell
```

---

## 5. Configuration

### Recording Settings

Add to `~/.config/thegrid/config.yaml`:

```yaml
settings:
  recording:
    outputDir: "~/Desktop/recordings"
```

**Properties:**

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `outputDir` | string | `""` (current directory) | Default output directory for recordings |

**Notes:**
- Supports `~` expansion
- Directory is created automatically if it doesn't exist
- Only used when `--output` flag is not provided
- Empty string means current working directory

---

## 6. Output Formats

### GIF

Palette-based animation format.

**Encoding process:**
1. Generate palette from input video (using `palettegen=stats_mode=diff`)
2. Apply palette with dithering

**Quality settings:**
- Low: No dithering (posterization visible)
- Medium: Bayer dithering with scale 5 (default)
- High: Sierra2_4a dithering (best gradients)

**Best for:**
- Sharing on platforms that support GIF
- Documentation and tutorials
- When file size is more important than quality

**Limitations:**
- 256 color palette
- No audio support
- Larger files than modern video codecs

### MP4

H.264 video codec.

**Encoding settings:**
- Codec: libx264
- Preset: medium
- Pixel format: yuv420p (universal compatibility)
- No audio stream

**Quality settings:**
- Low: CRF 28 (smaller files, visible compression)
- Medium: CRF 23 (balanced)
- High: CRF 18 (near-lossless)

**Best for:**
- General purpose video
- Presentations and demos
- Wide compatibility (all browsers, players)

**Limitations:**
- Requires ffmpeg
- No audio (use screencapture directly for audio)

### WebM

VP9 video codec.

**Encoding settings:**
- Codec: libvpx-vp9
- Bitrate mode: Constant quality (CRF)
- No audio stream

**Quality settings:**
- Low: CRF 40
- Medium: CRF 31
- High: CRF 24

**Best for:**
- Web embedding
- Maximum compression
- Modern browsers

**Limitations:**
- Requires ffmpeg
- Slower encoding than H.264
- Limited player support outside browsers

### MOV

Native QuickTime format from screencapture.

**Encoding:**
- No conversion (direct output from screencapture)
- H.264 codec
- No audio

**Best for:**
- No ffmpeg available
- Maximum quality (no re-encoding)
- Video editing (import to Final Cut, iMovie, etc.)

**Limitations:**
- Largest file size
- No scaling or optimization

---

## 7. Multi-Monitor Stitching

When recording `all` displays, theGrid stitches captures into a single video.

### Process

1. **Parallel capture**: Each display recorded simultaneously
2. **Bounding box calculation**: Compute canvas size from all display frames
3. **Canvas creation**: Black canvas at computed size
4. **Overlay positioning**: Each capture placed at real screen coordinates
5. **Stitch**: ffmpeg overlay filter combines all inputs

### Coordinate System

Uses macOS screen coordinate space:
- Origin (0,0) is bottom-left of main display
- Y-axis increases upward
- Each display has absolute X,Y position

### Example

Two monitors:
- Display 1: 1920x1080 at (0, 0)
- Display 2: 2560x1440 at (1920, -180)

Result:
- Canvas: 4480x1620
- Display 1 positioned at (0, 540)
- Display 2 positioned at (1920, 0)

### Codec Requirements

- Even dimensions enforced (rounded down if needed)
- All inputs must match framerate
- Uses `shortest=1` overlay mode

---

## 8. Follow Mode Details

### Focus Polling

Polls every 100ms during recording:
1. Fetch server snapshot
2. Reload state from disk (picks up focus changes from other commands)
3. Calculate cell bounds for current layout
4. Get focused cell ID and bounds
5. Record focus event with timestamp

### Deduplication

Consecutive focus events for the same cell are filtered out. Only cell changes are recorded.

### Crop Filter Construction

For each focus segment:
1. Split input video into N streams
2. Crop each stream to focused cell bounds
3. Scale to maximum dimensions
4. Trim to segment duration
5. Concatenate all segments

**Filter example (2 cells):**
```
[0:v]split=2[s0][s1];
[s0]crop=1920:1080:0:0,scale=1920:1080,trim=0.000:5.234,setpts=PTS-STARTPTS[c0];
[s1]crop=1280:720:1920:0,scale=1920:1080,trim=5.234:10.000,setpts=PTS-STARTPTS[c1];
[c0][c1]concat=n=2:v=1:a=0
```

### Limitations

- Focus changes faster than 100ms may be missed
- Requires persistent focus state updates (other grid commands must write to disk)
- No support for partial window focus (cell-level only)

---

## 9. File Naming

### Auto-Generated Names

Format: `recording-<label>-<timestamp>.<format>`

**Label patterns:**

| Target | Label |
|--------|-------|
| Cell | `cell-<id>` |
| Window | `window-<id>` |
| Screen | `screen` or `screen-<n>` |
| All | `all` |

**Timestamp format:** `YYYYMMDD-HHMMSS`

**Examples:**
- `recording-cell-main-20260215-143022.gif`
- `recording-window-12345-20260215-143105.mp4`
- `recording-screen-20260215-143200.webm`
- `recording-all-20260215-143245.mov`

### Custom Names

Use `--output` to override:

```bash
thegrid record -o demo.mp4
thegrid record -o ~/Desktop/tutorial.gif
```

Extension should match `--format`, but is not enforced.

---

## 10. Error Handling

### Common Errors

**No focused cell:**
```
Error: no focused cell
```
- Solution: Focus a cell first (`thegrid focus <cell>`)

**Cell not found:**
```
Error: cell "main" not found in layout
```
- Solution: Verify cell ID exists in active layout (`thegrid layout show`)

**No active layout:**
```
Error: no active layout
```
- Solution: Apply a layout first (`thegrid layout apply <id>`)

**ffmpeg not found:**
```
Warning: ffmpeg is required for GIF/MP4/WebM conversion.
Install with: brew install ffmpeg
Falling back to .mov format.
```
- Solution: Install ffmpeg or use MOV format explicitly

**Follow mode without ffmpeg:**
```
Error: --follow requires ffmpeg: ffmpeg is required for GIF/MP4/WebM conversion.
Install with: brew install ffmpeg
```
- Solution: Install ffmpeg

**Invalid display number:**
```
Error: display 3 not found (have 2 displays)
```
- Solution: Use valid display number (1-based indexing)

### Fallback Behavior

- **No ffmpeg + format=gif/mp4/webm**: Falls back to MOV, updates output path extension
- **No ffmpeg + target=all**: Error (stitching requires ffmpeg)
- **No focused cell/window**: Error (no fallback)

---

## 11. Performance Notes

### File Sizes

Approximate sizes for 5-second recording at 1920x1080:

| Format | Quality | Size |
|--------|---------|------|
| GIF | low | ~2 MB |
| GIF | medium | ~4 MB |
| GIF | high | ~6 MB |
| MP4 | low | ~500 KB |
| MP4 | medium | ~1 MB |
| MP4 | high | ~2 MB |
| WebM | low | ~300 KB |
| WebM | medium | ~600 KB |
| WebM | high | ~1.2 MB |
| MOV | - | ~8 MB |

### Encoding Speed

- MOV: Instant (no conversion)
- MP4: ~1x realtime (5s video = 5s encode)
- WebM: ~0.5x realtime (5s video = 10s encode)
- GIF: ~2x realtime (palette + encode)

### Disk I/O

- Temporary files created in `/tmp/thegrid-*`
- Cleaned up automatically after conversion
- Multi-monitor: One temp file per display + stitched output

---

## 12. Integration Examples

### BFD Hotkey Configuration

Add to `~/.config/thegrid/bfd.yaml`:

```yaml
vars:
  grid: ~/.local/bin/thegrid

hotkeys:
  # Toggle recording — press once to start, press again to stop
  ctrl-shift-r: @record toggle cell --open

  # Toggle follow-focus recording
  ctrl-shift-f: @record toggle cell --follow -f mp4 --cursor --open

  # Quick fixed-duration cell recording (5 seconds)
  ctrl-shift-g: @record start cell -d 5 --countdown 2 --open

  # High-quality window capture (10 seconds)
  ctrl-shift-w: @record start window -f mp4 -q high -d 10 --open
```

**Toggle commands** (`@record toggle`) are recommended for BFD because the same hotkey
starts and stops recording — no need to guess how long you need.

**Fixed-duration commands** (`@record start ... -d N`) are useful for quick captures
where you know the length in advance.

### Shell Aliases

Add to `~/.zshrc` or `~/.bashrc`:

```bash
alias grec="thegrid record"
alias grec-demo="thegrid record --follow -f mp4 --cursor -d 30 --open"
alias grec-gif="thegrid record -d 5 --countdown 2 --open"
```

### Scripted Workflows

```bash
#!/bin/bash
# Record a tutorial series

# Part 1: Setup
thegrid layout apply tutorial
thegrid focus main
thegrid record cell main -f mp4 -d 15 -o part1-setup.mp4

# Part 2: Demo with follow
thegrid record --follow -f mp4 -d 30 -o part2-demo.mp4 --cursor

# Part 3: Cleanup
thegrid focus terminal
thegrid record cell terminal -f mp4 -d 10 -o part3-cleanup.mp4
```

---

## 13. Advanced Use Cases

### Variable Frame Rate

```bash
# Smooth 60fps for animations
thegrid record cell editor -f mp4 --fps 60 -d 5

# Efficient 15fps for static content
thegrid record screen -f gif --fps 15 -d 10
```

### Scaled Output

```bash
# 4K source scaled to 1080p
thegrid record screen -f mp4 -w 1920 -q high

# Thumbnail GIF
thegrid record window -f gif -w 640
```

### Long Recordings

```bash
# 5-minute high-quality MP4
thegrid record screen -f mp4 -q high -d 300 --cursor

# Skip countdown for automated recordings
thegrid record cell main -d 60 --countdown 0
```

### Multi-Monitor Workflows

```bash
# Record all displays in real arrangement
thegrid record all -f mp4 -d 10

# Record specific external display
thegrid record screen 2 -f mp4 -d 15
```

### Tutorial Recording Workflow

```bash
# Start with overview of all displays
thegrid record all -f mp4 -d 5 -o 01-overview.mp4

# Follow-focus through workflow
thegrid record --follow -f mp4 -d 60 --cursor -o 02-workflow.mp4

# Close-up of final result
thegrid record cell output -f mp4 -q high -d 10 -o 03-result.mp4
```

---

## 14. Troubleshooting

### Recording shows wrong region

**Problem:** Cell or window bounds are incorrect.

**Solution:**
1. Verify layout is applied: `thegrid layout current`
2. Check cell bounds: `thegrid layout show`
3. Refresh reconcile state: `thegrid layout refresh`

### Follow mode doesn't track focus changes

**Problem:** Focus events not detected during recording.

**Solution:**
1. Ensure focus commands persist state to disk
2. Check state file is writable: `~/.local/state/thegrid/state.json`
3. Verify layout has focused cell before recording
4. Use explicit focus commands during recording

### Stitched output is black

**Problem:** Multi-monitor capture failed or coordinates wrong.

**Solution:**
1. Verify all displays are connected: `thegrid info`
2. Check display coordinates in server snapshot
3. Ensure ffmpeg is installed and working: `ffmpeg -version`

### Output file size too large

**Problem:** MOV format or high quality settings.

**Solution:**
1. Use MP4 or WebM format
2. Lower quality preset: `-q low`
3. Reduce FPS: `--fps 15`
4. Scale down: `-w 1280`

### Encoding fails with codec error

**Problem:** ffmpeg version or missing codec.

**Solution:**
1. Update ffmpeg: `brew upgrade ffmpeg`
2. Verify codecs available: `ffmpeg -codecs | grep -E "h264|vp9"`
3. Fall back to MOV format

---

## 15. JSON Output

Use `--json` global flag for machine-readable output:

```bash
thegrid record cell main -d 5 --json
```

**Output schema:**

```json
{
  "filePath": "/Users/username/recording-cell-main-20260215-143022.gif",
  "format": "gif",
  "size": 4194304,
  "duration": 5
}
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `filePath` | string | Absolute path to output file |
| `format` | string | Output format (gif, mp4, webm, mov) |
| `size` | int64 | File size in bytes |
| `duration` | int | Actual recording duration in seconds |

---

## 16. Related Commands

- `thegrid layout apply` - Apply layout before recording cells
- `thegrid focus` - Change focused cell/window
- `thegrid layout show` - View cell definitions and bounds
- `thegrid info` - Show display configuration
- `thegrid layout current` - Verify active layout

---

## 17. Implementation Notes

### Source Files

- `grid-server/Sources/GridServer/Grid/GridRecorder.swift` - Recording actor, capture, conversion, toggle support
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` - `@record` command dispatch
- `grid-server/Sources/GridServer/MessageHandler.swift` - RPC endpoints (`grid.record.start/stop/toggle`)
- `grid-server/Sources/GridCLI/RecordCommand.swift` - CLI command definition

### Key Types (Swift)

```swift
enum RecordingTarget: Sendable {
    case cell(id: String?)
    case window(id: UInt32?)
    case screen(index: Int?)
    case all
}

struct RecordingOptions: Sendable {
    var duration: Int? = nil   // nil = indefinite (toggle mode)
    var format: String = "gif"
    var quality: RecordingQuality = .medium
    // ... fps, width, countdown, cursor, open, follow
}

struct RecordingResult: Codable, Sendable {
    let filePath: String
    let format: String
    let size: Int64
    let duration: Int  // actual elapsed seconds
}
```

### Pipeline Flow

1. **Parse target** — `parseRecordingTarget(action:args:)` → `RecordingTarget`
2. **Resolve bounds** — `resolveTarget(target:gridState:gridConfig:stateManager:)` → `ResolvedTarget`
3. **Capture** — `captureRegion(region:duration:cursor:outPath:onProcess:)` or parallel captures
4. **Stitch** (if multi-region) — `stitchRecordings(inputs:output:regions:)`
5. **Follow crop** (if enabled) - `TrackFocus()` + `BuildCropFilter()` + `ApplyCropFilter()`
6. **Convert** (if not MOV) - `Convert(input, output, format, fps, width, quality)`
7. **Return result** - `Result{FilePath, Format, Size, Duration}`
