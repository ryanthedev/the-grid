# Pseudocode: Phase 11 - Recording

## Files to Create/Modify
- **Create:** `grid-server/Sources/GridServer/Grid/GridRecorder.swift`
- **Modify:** `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` (wire record domain)
- **Modify:** `grid-server/Sources/GridServer/MessageHandler.swift` (implement grid.record.start RPC)

## Design: GridRecorder

### Approaches Considered
1. **Monolithic class** -- Single GridRecorder class with all recording logic inline (ffmpeg, capture, stitch, follow, conversion)
2. **Actor with internal helpers** -- GridRecorder actor managing recording state, with static helper functions for ffmpeg/capture/convert
3. **Stateless module with value types** -- Pure functions + value types, recording state managed externally by caller

### Comparison
| Criterion | 1. Monolithic | 2. Actor + helpers | 3. Stateless |
|-----------|---------------|--------------------|----|
| Interface simplicity | Simple (1 method) | Simple (1 method) | Requires caller to manage state |
| Information hiding | All internal | All internal | Leaks recording state to caller |
| Lifecycle management | Must track active recording | Actor serializes naturally | Caller responsibility |
| Cancellation | Needs stored process ref | Actor stores process ref cleanly | Awkward |
| Follow mode | Internal subscription | Actor manages subscription lifecycle | Caller manages |

### Choice: 2 (Actor with internal helpers)
Rationale: Recording needs lifecycle management (cancellation on server shutdown, only one recording at a time, temp file cleanup). An actor naturally serializes access and owns the active recording state. Static helpers keep ffmpeg/conversion logic pure and testable. Sacrifices: slightly more structure than monolithic, but the lifecycle benefits outweigh.

### Depth Check
- Interface methods: 3 (record, cancel, isRecording)
- Hidden details: screencapture args, ffmpeg command construction, palette generation, stitch filter building, crop filter building, temp file management, follow mode event collection
- Common case complexity: simple -- caller says "record cell main for 5 seconds as gif"

---

## Pseudocode

### GridRecorder.swift

```
// MARK: - Types

enum RecordingTarget
    case cell(id: String?)      // nil = focused cell
    case window(id: UInt32?)    // nil = focused window
    case screen(index: Int?)    // nil = current display, 1-based
    case all                    // all displays stitched

enum RecordingQuality: String
    case low, medium, high

struct RecordingOptions
    duration: Int = 5           // seconds
    output: String? = nil       // nil = auto-generate
    outputDir: String = ""      // default output directory
    format: String = "gif"      // gif, mp4, webm, mov
    fps: Int = 0                // 0 = auto (10 gif, 30 video)
    width: Int = 0              // max width, 0 = no scaling
    quality: RecordingQuality = .medium
    countdown: Int = 3
    cursor: Bool = false
    open: Bool = false
    follow: Bool = false

    computed effectiveFPS -> Int
        if fps > 0 return fps
        if format == "gif" return 10
        return 30

struct RecordingResult: Codable
    filePath: String
    format: String
    size: Int64
    duration: Int

struct ResolvedTarget
    label: String
    regions: [CGRect]

// MARK: - FocusTracker (temporary EventRouter subscriber for follow mode)

class FocusTracker: StateEventHandler
    private var events: [(timestamp: TimeInterval, cellID: String, bounds: CGRect)] = []
    private let startTime: Date
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager

    init(gridState, gridConfig, stateManager)
        startTime = Date()
        // Capture initial focus position
        captureCurrentFocus()
        // Register with EventRouter
        EventRouter.shared.register(self)

    func handle(event, context) async throws
        // Only care about focusChanged events
        guard case .focusChanged(let focusState) = event else return

        // Get current cell bounds from GridState + GridLayout
        let spaceID = current space from stateManager
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState, layoutID = spaceState.currentLayoutID else return
        let layoutDef = gridConfig.getLayout(layoutID)
        let display = current display from stateManager
        let screenRect = display.visibleFrame
        let calculated = GridLayout.calculateLayoutWithRatios(layout, screenRect, gap, ratios)
        let cellID = spaceState.focusedCell
        guard let bounds = calculated.cellBounds[cellID] else return

        // Only record if cell actually changed
        guard cellID != events.last?.cellID else return

        let elapsed = Date().timeIntervalSince(startTime)
        events.append((timestamp: elapsed, cellID: cellID, bounds: bounds))

    func stop() -> [(timestamp: TimeInterval, cellID: String, bounds: CGRect)]
        EventRouter.shared.unregister(self)
        return events

    private func captureCurrentFocus()
        // Same logic as handle but synchronous initial capture

// MARK: - FFmpeg Helpers (static/free functions)

func findFfmpeg() -> String
    search paths: "ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"
    for each path, check if file exists at path (FileManager) or which returns valid
    return first found, or "ffmpeg" as fallback

func ffmpegAvailable() -> Bool
    return findFfmpeg() resolves to a real path

// MARK: - Capture (screencapture wrapper)

func buildCaptureArgs(region: CGRect, duration: Int, cursor: Bool, outPath: String) -> [String]
    args = ["-v"]
    append "-V" "\(duration)"
    if cursor: append "-C"
    append "-R" "\(Int(region.x)),\(Int(region.y)),\(Int(region.width)),\(Int(region.height))"
    append outPath
    return args

func capture(region: CGRect, duration: Int, cursor: Bool, outPath: String) async throws
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = buildCaptureArgs(region, duration, cursor, outPath)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    // Wait for completion using withCheckedThrowingContinuation
    // wrapping process.terminationHandler
    if process.terminationStatus != 0
        throw RecordingError.captureFailed(output from pipe)

// MARK: - Conversion (ffmpeg wrappers)

func convert(input: String, output: String, format: String, fps: Int, width: Int, quality: RecordingQuality) throws
    switch format
        case "gif": convertGIF(input, output, fps, width, quality)
        case "mp4": convertMP4(input, output, fps, width, quality)
        case "webm": convertWebM(input, output, fps, width, quality)
        case "mov": no-op (screencapture produces mov natively)

func convertGIF(input, output, fps, width, quality)
    // Step 1: Generate palette
    vf = "fps=\(fps)"
    if width > 0: vf += ",scale=\(width):-1:flags=lanczos"
    paletteFile = output + ".palette.png"
    run ffmpeg: -y -i input -vf vf+",palettegen=stats_mode=diff" paletteFile

    // Step 2: Create GIF with palette
    dither = based on quality: low="none", medium="bayer:bayer_scale=5", high="sierra2_4a"
    filter = "\(vf)[x];[x][1:v]paletteuse=dither=\(dither)"
    run ffmpeg: -y -i input -i paletteFile -filter_complex filter output

    // Cleanup palette
    try? FileManager.removeItem(paletteFile)

func convertMP4(input, output, fps, width, quality)
    crf = low:28, medium:23, high:18
    vf = "fps=\(fps)"
    if width > 0: vf += ",scale=\(width):-2:flags=lanczos"
    run ffmpeg: -y -i input -vf vf -c:v libx264 -preset medium -crf crf -pix_fmt yuv420p -an output

func convertWebM(input, output, fps, width, quality)
    crf = low:40, medium:31, high:24
    vf = "fps=\(fps)"
    if width > 0: vf += ",scale=\(width):-2:flags=lanczos"
    run ffmpeg: -y -i input -vf vf -c:v libvpx-vp9 -crf crf -b:v 0 -an output

// MARK: - Stitch (multi-monitor overlay)

func stitch(inputs: [String], output: String, regions: [CGRect]) throws
    if inputs.count == 1: just rename file, return

    // Compute bounding box of all regions
    minX, minY = min of all regions' origins
    maxX, maxY = max of all regions' (origin + size)

    // Canvas size (ensure even dimensions for codec)
    canvasW = Int(maxX - minX) & ~1
    canvasH = Int(maxY - minY) & ~1

    // Build ffmpeg args
    args = ["-y", "-f", "lavfi", "-i", "color=c=black:s=\(canvasW)x\(canvasH):r=30"]
    for each input file: append "-i" inputFile

    // Build overlay filter chain
    // Input 0 = black canvas, inputs 1..n = captures
    filter = ""
    prev = "0:v"
    for i in 0..<n
        ox = Int(regions[i].x - minX)
        oy = Int(regions[i].y - minY)
        if i == n-1:
            filter += "[\(prev)][\(i+1):v]overlay=\(ox):\(oy):shortest=1"
        else:
            outLabel = "out\(i)"
            filter += "[\(prev)][\(i+1):v]overlay=\(ox):\(oy):shortest=1[\(outLabel)];"
            prev = outLabel

    args += ["-filter_complex", filter, "-an", output]
    run ffmpeg with args

// MARK: - Follow Mode (crop filter)

func buildCropFilter(events: [(TimeInterval, String, CGRect)], recordingDuration: Double) -> (filter: String, outW: Int, outH: Int)
    // Find max width and height across all events
    maxW = max of all event bounds widths
    maxH = max of all event bounds heights
    outW = Int(maxW) & ~1 (ensure even)
    outH = Int(maxH) & ~1 (ensure even)
    clamp minimum to 2

    if single event:
        filter = "crop=w:h:x:y,scale=outW:outH"
        return

    // Multi-event: split -> crop+trim each segment -> concat
    // Split input into N copies
    splitLabels = "[s0][s1]...[sN-1]"
    parts = ["[0:v]split=N" + splitLabels]

    for each event i:
        startTime = event.timestamp
        endTime = next event's timestamp (or recordingDuration for last)
        ensure endTime > startTime
        segment = "[sI]crop=w:h:x:y,scale=outW:outH,trim=start:end,setpts=PTS-STARTPTS[cI]"
        parts.append(segment)

    // Concat all segments
    concatInputs = "[c0][c1]...[cN-1]"
    parts.append(concatInputs + "concat=n=N:v=1:a=0")

    filter = parts joined by ";"
    return (filter, outW, outH)

func applyCropFilter(input: String, output: String, filter: String) throws
    run ffmpeg: -y -i input -filter_complex filter -an output

// MARK: - Target Resolution

func resolveTarget(
    target: RecordingTarget,
    gridState: GridState,
    gridConfig: GridConfig,
    stateManager: StateManager
) async throws -> ResolvedTarget

    switch target:
    case .cell(let id):
        // Get current space from stateManager
        let wmState = stateManager.getState()
        let currentDisplay = wmState.displays.first(where: { $0.isMain == true }) ?? wmState.displays[0]
        let spaceID = String(currentDisplay.currentSpaceID)

        // Get space state from GridState
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard let spaceState else throw "no state for space"
        guard let layoutID = spaceState.currentLayoutID, !layoutID.isEmpty else throw "no active layout"

        // Get layout definition
        let layoutDef = gridConfig.getLayout(layoutID)

        // Calculate cell bounds
        let screenRect = currentDisplay.visibleFrame ?? currentDisplay.frame ?? .zero
        let gap = gridConfig.settings.gap
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef, screenRect: screenRect, gap: gap,
            columnRatios: spaceState.columnRatios, rowRatios: spaceState.rowRatios
        )

        // Resolve cell ID (default to focused cell)
        let cellID = id ?? spaceState.focusedCell
        guard !cellID.isEmpty else throw "no focused cell"
        guard let bounds = calculated.cellBounds[cellID] else throw "cell not in layout"

        return ResolvedTarget(label: "cell-\(cellID)", regions: [bounds])

    case .window(let id):
        let wmState = stateManager.getState()
        let wid: UInt32
        if let id then wid = id
        else wid = focused window ID from wmState.metadata
        guard wid != 0 else throw "no focused window"

        let windowKey = String(wid)
        guard let window = wmState.windows[windowKey] else throw "window not found"
        return ResolvedTarget(label: "window-\(wid)", regions: [window.frame])

    case .screen(let index):
        let wmState = stateManager.getState()
        guard !wmState.displays.isEmpty else throw "no displays"

        if let index then
            let idx = index - 1  // 1-based to 0-based
            guard idx >= 0 && idx < wmState.displays.count else throw "display not found"
            let d = wmState.displays[idx]
            return ResolvedTarget(label: "screen-\(index)", regions: [d.frame ?? .zero])
        else
            // Current display
            let current = wmState.displays.first(where: { $0.isMain == true }) ?? wmState.displays[0]
            return ResolvedTarget(label: "screen", regions: [current.frame ?? .zero])

    case .all:
        let wmState = stateManager.getState()
        guard !wmState.displays.isEmpty else throw "no displays"
        let regions = wmState.displays.compactMap(\.frame).sorted(by: { $0.origin.x < $1.origin.x })
        return ResolvedTarget(label: "all", regions: regions)

// MARK: - GridRecorder Actor

actor GridRecorder
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager
    private var activeProcess: Process?
    private var isActive: Bool = false

    init(gridState, gridConfig, stateManager)

    func record(target: RecordingTarget, options: RecordingOptions) async throws -> RecordingResult
        guard !isActive else throw "recording already in progress"
        isActive = true
        defer { isActive = false; cleanup() }

        // Resolve target to pixel bounds
        let resolved = try await resolveTarget(target, gridState, gridConfig, stateManager)

        // Determine output path
        let outPath = options.output ?? generateOutputPath(options.outputDir, resolved.label, options.format)

        // Check ffmpeg requirement
        var format = options.format
        let needsFFmpeg = format != "mov" || resolved.regions.count > 1
        if needsFFmpeg && !ffmpegAvailable()
            jlog("record.ffmpeg.missing")
            format = "mov"
            // Adjust extension in outPath

        let fps = options.effectiveFPS

        // Countdown (if > 0)
        if options.countdown > 0
            try await Task.sleep(for: .seconds(options.countdown))

        // Capture phase
        var capturedFile: String

        if options.follow
            // Follow mode: capture full screen, track focus changes
            let fullScreenRegion = first display frame from stateManager
            capturedFile = tempPath("recording", "mov")

            // Start focus tracker
            let tracker = FocusTracker(gridState, gridConfig, stateManager)

            // Capture full screen
            try await capture(fullScreenRegion, options.duration, options.cursor, capturedFile)

            // Stop tracking, get events
            let focusEvents = tracker.stop()

            // Apply crop filter if we got focus events
            if !focusEvents.isEmpty
                let (filter, outW, outH) = buildCropFilter(focusEvents, Double(options.duration))
                let croppedFile = tempPath("cropped", "mov")
                try applyCropFilter(capturedFile, croppedFile, filter)
                try? FileManager.removeItem(capturedFile)
                capturedFile = croppedFile

        else if resolved.regions.count == 1
            // Single region capture
            capturedFile = tempPath("recording", "mov")
            try await capture(resolved.regions[0], options.duration, options.cursor, capturedFile)

        else
            // Multi-region: capture in parallel, then stitch
            let tmpFiles = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (i, region) in resolved.regions.enumerated()
                    group.addTask
                        let path = tempPath("region-\(i)", "mov")
                        try await capture(region, options.duration, options.cursor, path)
                        return (i, path)
                var results = [(Int, String)]()
                for try await result in group
                    results.append(result)
                return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }

            capturedFile = tempPath("stitched", "mov")
            try stitch(tmpFiles, capturedFile, resolved.regions)

            // Cleanup temp files
            for f in tmpFiles
                try? FileManager.removeItem(f)

        defer { try? FileManager.removeItem(capturedFile) }

        // Convert phase
        if format == "mov"
            try FileManager.moveItem(capturedFile, outPath)
        else
            try convert(capturedFile, outPath, format, fps, options.width, options.quality)

        // Get file size
        let attrs = try FileManager.attributesOfItem(outPath)
        let size = attrs[.size] as? Int64 ?? 0

        // Open if requested
        if options.open
            Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [outPath])

        return RecordingResult(filePath: outPath, format: format, size: size, duration: options.duration)

    func cancel()
        activeProcess?.terminate()
        isActive = false

    var recording: Bool { isActive }

    private func cleanup()
        // Remove any lingering temp files matching "thegrid-*" in temp dir
        // Best-effort only

    private func tempPath(_ prefix: String, _ ext: String) -> String
        let ts = Int(Date().timeIntervalSince1970 * 1_000_000)
        return NSTemporaryDirectory() + "thegrid-\(prefix)-\(ts).\(ext)"

    private func generateOutputPath(_ dir: String, _ label: String, _ format: String) -> String
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ts = formatter.string(from: Date())
        let name = "recording-\(label)-\(ts).\(format)"
        if !dir.isEmpty
            return (dir as NSString).appendingPathComponent(name)
        return name

// MARK: - Process runner helper

func runProcess(executable: String, arguments: [String]) throws
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw RecordingError.processFailed(executable, process.terminationStatus, output)

enum RecordingError: Error
    case captureFailed(String)
    case processFailed(String, Int32, String)
    case targetResolutionFailed(String)
    case alreadyRecording
    case ffmpegNotAvailable
```

### GridCommandRouter.swift (modification)

```
// In dispatch(), replace the record stub:
case "record":
    return try await handleRecord(parsed)

// Add handler method:
func handleRecord(parsed) async throws -> CommandResult
    let target = parseRecordingTarget(parsed.action, parsed.args)
    // action = "start" (or default)
    // Extract options from parsed flags
    var options = RecordingOptions()
    if let d = parsed.flag("duration") as Int: options.duration = d
    if let f = parsed.flag("format"): options.format = f
    if let q = parsed.flag("quality"): options.quality = RecordingQuality(rawValue: q)
    if parsed.hasFlag("cursor"): options.cursor = true
    if parsed.hasFlag("follow"): options.follow = true
    if parsed.hasFlag("open"): options.open = true
    // ... other flags

    if parsed.action == "cancel"
        await gridRecorder.cancel()
        return .success("recording cancelled")

    if parsed.action == "status"
        let active = await gridRecorder.recording
        return .success(active ? "recording" : "idle")

    let result = try await gridRecorder.record(target: target, options: options)
    return .success(result as JSON)

func parseRecordingTarget(action: String, args: [String]) -> RecordingTarget
    // first arg (or action if not "start") determines target type
    let targetStr = args.first ?? "cell"
    let id = args.count > 1 ? args[1] : nil
    switch targetStr
        case "cell": return .cell(id: id)
        case "window": return .window(id: UInt32(id))
        case "screen": return .screen(index: Int(id))
        case "all": return .all
        default: return .cell(id: nil)
```

### MessageHandler.swift (modification)

```
// Replace grid.record.start stub with:
register(method: "grid.record.start") { [weak self] request, completion in
    guard let self else return
    Task {
        do {
            // Parse params from request
            let target = parseTargetFromParams(request.params)
            let options = parseOptionsFromParams(request.params)
            let result = try await self.gridRecorder.record(target: target, options: options)
            let encoder = JSONEncoder()
            let data = try encoder.encode(result)
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            completion(Response(id: request.id, result: dict))
        } catch {
            completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: error.localizedDescription)))
        }
    }
}
```

## Design Notes

1. **Actor vs class:** GridRecorder is an actor because it manages mutable state (isActive, activeProcess) and needs safe concurrent access. The recording runs on a background task but the actor serializes start/cancel/status queries.

2. **FocusTracker as class (not actor):** Implements StateEventHandler protocol which requires class. Uses EventRouter register/unregister for lifecycle. Collects events in an array -- thread safety is handled by EventRouter dispatching events sequentially.

3. **Process cancellation:** The activeProcess reference lets cancel() terminate a running screencapture. On server shutdown, cancel() should be called to clean up.

4. **Follow mode simplification:** Go version polls state.json every 100ms because it runs as a separate process. Swift version subscribes to EventRouter for real-time focus events -- no polling, no disk I/O, more accurate.

5. **screencapture path:** Using `/usr/sbin/screencapture` as absolute path since server runs with minimal PATH.

6. **Temp file naming:** Uses microsecond timestamp to avoid collisions during parallel multi-region capture.

7. **GridRecorder ownership:** Created in main.swift, passed to GridCommandRouter and MessageHandler. Lifecycle matches server lifetime.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (deep module analysis done)
- [x] Ready for implementation
