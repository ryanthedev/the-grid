# Discovery: Phase 11 - Recording

## Files Found

### Go Source (to port)
- `grid-cli/internal/record/record.go` -- orchestrator: Options, Result, Record(), tempPath()
- `grid-cli/internal/record/capture.go` -- BuildCaptureArgs(), Capture() via screencapture
- `grid-cli/internal/record/convert.go` -- Convert(), Stitch(), convertGIF/MP4/WebM(), QualityLevel
- `grid-cli/internal/record/ffmpeg.go` -- FindFfmpeg(), FFmpegAvailable(), InstallHint()
- `grid-cli/internal/record/target.go` -- ParseTarget(), ResolveTarget(), resolveCell/Window/Screen/All
- `grid-cli/internal/record/follow.go` -- FollowContext, TrackFocus(), FocusEvent, BuildCropFilter(), ApplyCropFilter()

### Swift Server (dependencies, already built)
- `Grid/GridState.swift` -- actor with getSpace(), getSpaceReadOnly(), focusedCell, focusedWindow, currentLayoutID
- `Grid/GridLayout.swift` -- calculateLayoutWithRatios() returns GridCalculatedLayout with cellBounds: [String: CGRect]
- `Grid/GridConfig.swift` -- layout definitions, getLayout()
- `Grid/GridCommandRouter.swift` -- already has `case "record"` returning stub error
- `Grid/GridReconciler.swift` -- subscribes to EventRouter for focusChanged events
- `StateManager.swift` -- getState() returns WindowManagerState with displays: [DisplayState]
- `StateModels.swift` -- DisplayState has frame: CGRect?, visibleFrame: CGRect?, WindowState has frame
- `MessageHandler.swift` -- has `grid.record.start` RPC stub
- `Sources/GridCLI/RecordCommand.swift` -- CLI command already wired, sends params via `grid.record.start` RPC

## Current State

Phase 1-10 are complete. The recording infrastructure has:
- A stub in `GridCommandRouter.swift` returning `.error("record not yet implemented")`
- A stub in `MessageHandler.swift` returning error for `grid.record.start`
- A CLI `RecordCommand.swift` already sending all params via RPC

What needs to be built:
- `Grid/GridRecorder.swift` -- the actual recording implementation

## Key Differences from Go

1. **No snapshot fetch needed.** Go's target resolution calls `server.Fetch()` over RPC to get window/display state. Swift has direct access to `StateManager.getState()` and `GridState`.

2. **No polling for follow mode.** Go's `TrackFocus` polls state.json from disk every 100ms. Swift can subscribe to `EventRouter` for real-time focus change events (same mechanism GridReconciler uses).

3. **Process() instead of exec.Command().** Swift's `Process` class is the equivalent. Nearly identical API.

4. **CGRect instead of types.Rect.** Already used throughout the Swift codebase.

5. **Async/await instead of goroutines.** Multi-region parallel capture uses `TaskGroup` instead of `sync.WaitGroup`.

## Gaps

1. **No gap in dependencies.** All required APIs exist (GridState, GridLayout, GridConfig, StateManager, EventRouter).

2. **GridCommandRouter record case** needs implementation (currently returns error string).

3. **MessageHandler grid.record.start** needs implementation (currently returns error).

4. **EventRouter subscription for follow mode** -- need to verify if a transient subscriber pattern exists or if we need to add one. GridReconciler registers as a `StateEventHandler` permanently. Follow mode needs a temporary subscription that starts/stops with recording.

## Prerequisites
- [x] GridState actor exists with space/cell/focus accessors
- [x] GridLayout.calculateLayoutWithRatios() returns cell bounds
- [x] GridConfig provides layout definitions
- [x] StateManager.getState() provides displays and windows
- [x] EventRouter exists for focus change events
- [x] GridCommandRouter has record domain stub
- [x] RPC handler has grid.record.start stub
- [x] CLI RecordCommand already sends all params

## Recommendation
BUILD -- all prerequisites met, clear port path from Go to Swift
