import Foundation
import CoreGraphics

// MARK: - Types

enum RecordingTarget: Sendable {
    case cell(id: String?)
    case window(id: UInt32?)
    case screen(index: Int?)
    case all
}

enum RecordingQuality: String, Sendable {
    case low, medium, high
}

struct RecordingOptions: Sendable {
    // nil means indefinite (toggle mode); non-nil means fixed duration in seconds
    var duration: Int? = nil
    var output: String? = nil
    var outputDir: String = ""
    var format: String = "mp4"
    var fps: Int = 0
    var width: Int = 0
    var quality: RecordingQuality = .medium
    var countdown: Int = 3
    var cursor: Bool = false
    var open: Bool = false
    var follow: Bool = false

    var effectiveFPS: Int {
        if fps > 0 { return fps }
        if format == "gif" { return 10 }
        return 30
    }
}

struct RecordingResult: Codable, Sendable {
    let filePath: String
    let format: String
    let size: Int64
    // For toggle recordings this is actual elapsed seconds (rounded); for fixed-duration it equals options.duration
    let duration: Int
}

struct ResolvedTarget: Sendable {
    let label: String
    let regions: [CGRect]
}

enum RecordingError: Error, LocalizedError {
    case captureFailed(String)
    case processFailed(String, Int32, String)
    case targetResolutionFailed(String)
    case alreadyRecording
    case ffmpegNotAvailable

    var errorDescription: String? {
        switch self {
        case .captureFailed(let output):
            return "capture failed: \(output)"
        case .processFailed(let exe, let code, let output):
            return "\(exe) failed (exit \(code)): \(output)"
        case .targetResolutionFailed(let reason):
            return "target resolution failed: \(reason)"
        case .alreadyRecording:
            return "recording already in progress"
        case .ffmpegNotAvailable:
            return "ffmpeg not available"
        }
    }
}

// MARK: - FocusTracker (temporary EventRouter subscriber for follow mode)

class FocusTracker: StateEventHandler {
    private var events: [(timestamp: TimeInterval, cellID: String, bounds: CGRect)] = []
    private let startTime: Date
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager

    init(gridState: GridState, gridConfig: GridConfig, stateManager: StateManager) {
        self.startTime = Date()
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager

        // Capture initial focus position
        Task {
            await captureCurrentFocus()
            await EventRouter.shared.register(self)
        }
    }

    func handle(_ event: StateEvent, context: EventContext) async throws {
        // Only care about focusChanged events
        guard case .focusChanged = event else { return }

        await captureCurrentFocus()
    }

    func stop() -> [(timestamp: TimeInterval, cellID: String, bounds: CGRect)] {
        Task {
            await EventRouter.shared.unregister(self)
        }
        return events
    }

    private func captureCurrentFocus() async {
        // Get current space from stateManager
        let wmState = await stateManager.getState()
        // Use metadata.activeDisplayUUID to find the focused display (not isMain which is the primary monitor)
        let currentDisplay: DisplayState?
        if let activeUUID = wmState.metadata.activeDisplayUUID {
            currentDisplay = wmState.displays.first(where: { $0.uuid == activeUUID }) ?? wmState.displays.first
        } else {
            currentDisplay = wmState.displays.first
        }
        guard let currentDisplay else { return }
        let spaceID = String(currentDisplay.currentSpaceID)

        // Get space state from GridState
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard let spaceState else { return }
        guard !spaceState.currentLayoutId.isEmpty else { return }
        let layoutID = spaceState.currentLayoutId

        // Get layout definition
        guard let layoutDef = try? await MainActor.run(body: { try gridConfig.getLayout(id: layoutID) }) else { return }

        // Calculate cell bounds
        let screenRect = currentDisplay.visibleFrame ?? currentDisplay.frame ?? .zero
        let gap = await MainActor.run { gridConfig.getBaseSpacing() }
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: screenRect,
            gap: gap,
            columnRatios: spaceState.columnRatios,
            rowRatios: spaceState.rowRatios
        )

        let cellID = spaceState.focusedCell
        guard !cellID.isEmpty else { return }
        guard let bounds = calculated.cellBounds[cellID] else { return }

        // Only record if cell actually changed
        guard cellID != events.last?.cellID else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        events.append((timestamp: elapsed, cellID: cellID, bounds: bounds))
    }
}

// MARK: - FFmpeg Helpers

func findFfmpeg() -> String {
    let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]
    let fm = FileManager.default
    for path in searchPaths {
        if fm.fileExists(atPath: path) {
            return path
        }
    }
    return "ffmpeg"
}

func ffmpegAvailable() -> Bool {
    let path = findFfmpeg()
    return FileManager.default.fileExists(atPath: path)
}

// MARK: - Capture (screencapture wrapper)

// duration is optional: non-nil appends -V <seconds> for fixed-duration capture;
// nil omits -V so screencapture records indefinitely until interrupted (SIGINT).
func buildCaptureArgs(region: CGRect, duration: Int?, cursor: Bool, outPath: String) -> [String] {
    var args = ["-v"]
    if let duration = duration {
        args += ["-V", "\(duration)"]
    }
    if cursor {
        args.append("-C")
    }
    args += ["-R", "\(Int(region.origin.x)),\(Int(region.origin.y)),\(Int(region.width)),\(Int(region.height))"]
    args.append(outPath)
    return args
}

// Captures a screen region to a MOV file. For fixed-duration, terminates automatically.
// For indefinite mode (duration nil), blocks until the caller sends SIGINT via the process
// surfaced through onProcess. Exit status 2 (SIGINT) is treated as success because
// screencapture finalizes the MOV container cleanly before exiting on SIGINT.
func captureRegion(
    region: CGRect,
    duration: Int?,
    cursor: Bool,
    outPath: String,
    onProcess: @escaping (Process) -> Void
) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = buildCaptureArgs(region: region, duration: duration, cursor: cursor, outPath: outPath)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()

    // Surface the Process ref before blocking so the actor can store it for stop()/cancel()
    onProcess(process)

    // Wait for completion using continuation
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            if status == 0 || status == 2 {
                // 0 = normal end (fixed duration), 2 = SIGINT (indefinite stop)
                continuation.resume()
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(throwing: RecordingError.captureFailed(output))
            }
        }
    }
}

// MARK: - Process runner helper

func runProcess(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        throw RecordingError.processFailed(executable, process.terminationStatus, output)
    }
}

// MARK: - Conversion (ffmpeg wrappers)

func convertRecording(input: String, output: String, format: String, fps: Int, width: Int, quality: RecordingQuality) throws {
    switch format {
    case "gif":
        try convertGIF(input: input, output: output, fps: fps, width: width, quality: quality)
    case "mp4":
        try convertMP4(input: input, output: output, fps: fps, width: width, quality: quality)
    case "webm":
        try convertWebM(input: input, output: output, fps: fps, width: width, quality: quality)
    case "mov":
        // screencapture produces mov natively, no conversion needed
        break
    default:
        try convertGIF(input: input, output: output, fps: fps, width: width, quality: quality)
    }
}

func convertGIF(input: String, output: String, fps: Int, width: Int, quality: RecordingQuality) throws {
    let ffmpeg = findFfmpeg()

    // Step 1: Generate palette
    var vf = "fps=\(fps)"
    if width > 0 {
        vf += ",scale=\(width):-1:flags=lanczos"
    }
    let paletteFile = output + ".palette.png"
    try runProcess(executable: ffmpeg, arguments: [
        "-y", "-i", input,
        "-vf", vf + ",palettegen=stats_mode=diff",
        "-frames:v", "1", "-update", "1",
        paletteFile,
    ])

    // Step 2: Create GIF with palette
    let dither: String
    switch quality {
    case .low:
        dither = "none"
    case .medium:
        dither = "bayer:bayer_scale=5"
    case .high:
        dither = "sierra2_4a"
    }
    let filter = "\(vf)[x];[x][1:v]paletteuse=dither=\(dither)"
    try runProcess(executable: ffmpeg, arguments: [
        "-y", "-i", input, "-i", paletteFile,
        "-filter_complex", filter,
        output,
    ])

    // Cleanup palette
    try? FileManager.default.removeItem(atPath: paletteFile)
}

func convertMP4(input: String, output: String, fps: Int, width: Int, quality: RecordingQuality) throws {
    let ffmpeg = findFfmpeg()
    let crf: Int
    switch quality {
    case .low: crf = 28
    case .medium: crf = 23
    case .high: crf = 18
    }
    var vf = "fps=\(fps)"
    if width > 0 {
        vf += ",scale=\(width):-2:flags=lanczos"
    }
    try runProcess(executable: ffmpeg, arguments: [
        "-y", "-i", input,
        "-vf", vf,
        "-c:v", "libx264", "-preset", "medium",
        "-crf", "\(crf)",
        "-pix_fmt", "yuv420p",
        "-an",
        output,
    ])
}

func convertWebM(input: String, output: String, fps: Int, width: Int, quality: RecordingQuality) throws {
    let ffmpeg = findFfmpeg()
    let crf: Int
    switch quality {
    case .low: crf = 40
    case .medium: crf = 31
    case .high: crf = 24
    }
    var vf = "fps=\(fps)"
    if width > 0 {
        vf += ",scale=\(width):-2:flags=lanczos"
    }
    try runProcess(executable: ffmpeg, arguments: [
        "-y", "-i", input,
        "-vf", vf,
        "-c:v", "libvpx-vp9",
        "-crf", "\(crf)",
        "-b:v", "0",
        "-an",
        output,
    ])
}

// MARK: - Stitch (multi-monitor overlay)

func stitchRecordings(inputs: [String], output: String, regions: [CGRect]) throws {
    if inputs.count == 1 {
        try FileManager.default.moveItem(atPath: inputs[0], toPath: output)
        return
    }

    // Compute bounding box of all regions
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity
    for r in regions {
        minX = min(minX, r.origin.x)
        minY = min(minY, r.origin.y)
        maxX = max(maxX, r.origin.x + r.width)
        maxY = max(maxY, r.origin.y + r.height)
    }

    // Canvas size (ensure even dimensions for codec)
    let canvasW = Int(maxX - minX) & ~1
    let canvasH = Int(maxY - minY) & ~1

    // Build ffmpeg args
    var args = ["-y", "-f", "lavfi", "-i", "color=c=black:s=\(canvasW)x\(canvasH):r=30"]
    for input in inputs {
        args += ["-i", input]
    }

    // Build overlay filter chain
    var filter = ""
    var prev = "0:v"
    let n = inputs.count
    for i in 0..<n {
        let ox = Int(regions[i].origin.x - minX)
        let oy = Int(regions[i].origin.y - minY)
        if i == n - 1 {
            filter += "[\(prev)][\(i + 1):v]overlay=\(ox):\(oy):shortest=1"
        } else {
            let outLabel = "out\(i)"
            filter += "[\(prev)][\(i + 1):v]overlay=\(ox):\(oy):shortest=1[\(outLabel)];"
            prev = outLabel
        }
    }

    args += ["-filter_complex", filter, "-an", output]

    let ffmpeg = findFfmpeg()
    try runProcess(executable: ffmpeg, arguments: args)
}

// MARK: - Follow Mode (crop filter)

func buildCropFilter(
    events: [(timestamp: TimeInterval, cellID: String, bounds: CGRect)],
    recordingDuration: Double
) -> (filter: String, outW: Int, outH: Int) {
    // Find max width and height across all events
    var maxW: CGFloat = 0
    var maxH: CGFloat = 0
    for e in events {
        maxW = max(maxW, e.bounds.width)
        maxH = max(maxH, e.bounds.height)
    }
    var outW = Int(maxW) & ~1
    var outH = Int(maxH) & ~1
    // Clamp minimum to 2
    outW = max(outW, 2)
    outH = max(outH, 2)

    if events.count == 1 {
        let b = events[0].bounds
        let filter = "crop=\(Int(b.width)):\(Int(b.height)):\(Int(b.origin.x)):\(Int(b.origin.y)),scale=\(outW):\(outH)"
        return (filter, outW, outH)
    }

    // Multi-event: split -> crop+trim each segment -> concat
    let n = events.count
    var splitLabels = ""
    for i in 0..<n {
        splitLabels += "[s\(i)]"
    }
    var parts = ["[0:v]split=\(n)" + splitLabels]

    for i in 0..<n {
        let startTime = events[i].timestamp
        let endTime: TimeInterval
        if i < n - 1 {
            endTime = events[i + 1].timestamp
        } else {
            endTime = recordingDuration
        }
        // Ensure endTime > startTime
        let safeEnd = max(endTime, startTime + 0.001)

        let b = events[i].bounds
        let segment = "[s\(i)]crop=\(Int(b.width)):\(Int(b.height)):\(Int(b.origin.x)):\(Int(b.origin.y)),scale=\(outW):\(outH),trim=start=\(startTime):end=\(safeEnd),setpts=PTS-STARTPTS[c\(i)]"
        parts.append(segment)
    }

    // Concat all segments
    var concatInputs = ""
    for i in 0..<n {
        concatInputs += "[c\(i)]"
    }
    parts.append(concatInputs + "concat=n=\(n):v=1:a=0")

    let filter = parts.joined(separator: ";")
    return (filter, outW, outH)
}

func applyCropFilter(input: String, output: String, filter: String) throws {
    let ffmpeg = findFfmpeg()
    try runProcess(executable: ffmpeg, arguments: [
        "-y", "-i", input,
        "-filter_complex", filter,
        "-an",
        output,
    ])
}

// MARK: - Target Resolution

func resolveTarget(
    target: RecordingTarget,
    gridState: GridState,
    gridConfig: GridConfig,
    stateManager: StateManager
) async throws -> ResolvedTarget {
    switch target {
    case .cell(let id):
        // Get current space from stateManager
        let wmState = await stateManager.getState()
        // Use metadata.activeDisplayUUID to find the focused display (not isMain which is the primary monitor)
        let currentDisplay: DisplayState?
        if let activeUUID = wmState.metadata.activeDisplayUUID {
            currentDisplay = wmState.displays.first(where: { $0.uuid == activeUUID }) ?? wmState.displays.first
        } else {
            currentDisplay = wmState.displays.first
        }
        guard let currentDisplay else {
            throw RecordingError.targetResolutionFailed("no displays")
        }
        let spaceID = String(currentDisplay.currentSpaceID)

        // Get space state from GridState
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard let spaceState else {
            throw RecordingError.targetResolutionFailed("no state for space \(spaceID)")
        }
        guard !spaceState.currentLayoutId.isEmpty else {
            throw RecordingError.targetResolutionFailed("no active layout")
        }
        let layoutID = spaceState.currentLayoutId

        // Get layout definition
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }

        // Calculate cell bounds
        let screenRect = currentDisplay.visibleFrame ?? currentDisplay.frame ?? .zero
        let gap = await MainActor.run { gridConfig.getBaseSpacing() }
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: screenRect,
            gap: gap,
            columnRatios: spaceState.columnRatios,
            rowRatios: spaceState.rowRatios
        )

        // Resolve cell ID (default to focused cell)
        let cellID = id ?? spaceState.focusedCell
        guard !cellID.isEmpty else {
            throw RecordingError.targetResolutionFailed("no focused cell")
        }
        guard let bounds = calculated.cellBounds[cellID] else {
            throw RecordingError.targetResolutionFailed("cell '\(cellID)' not in layout")
        }

        return ResolvedTarget(label: "cell-\(cellID)", regions: [bounds])

    case .window(let id):
        let wmState = await stateManager.getState()
        let wid: UInt32
        if let id = id {
            wid = id
        } else {
            wid = wmState.metadata.focusedWindowID ?? 0
        }
        guard wid != 0 else {
            throw RecordingError.targetResolutionFailed("no focused window")
        }

        let windowKey = String(wid)
        guard let window = wmState.windows[windowKey] else {
            throw RecordingError.targetResolutionFailed("window \(wid) not found")
        }
        return ResolvedTarget(label: "window-\(wid)", regions: [window.frame])

    case .screen(let index):
        let wmState = await stateManager.getState()
        guard !wmState.displays.isEmpty else {
            throw RecordingError.targetResolutionFailed("no displays")
        }

        if let index = index {
            let idx = index - 1
            guard idx >= 0 && idx < wmState.displays.count else {
                throw RecordingError.targetResolutionFailed("display \(index) not found")
            }
            let d = wmState.displays[idx]
            return ResolvedTarget(label: "screen-\(index)", regions: [d.frame ?? .zero])
        } else {
            // Current display (use focused display, not primary monitor)
            let current: DisplayState
            if let activeUUID = wmState.metadata.activeDisplayUUID,
               let active = wmState.displays.first(where: { $0.uuid == activeUUID }) {
                current = active
            } else {
                current = wmState.displays[0]
            }
            return ResolvedTarget(label: "screen", regions: [current.frame ?? .zero])
        }

    case .all:
        let wmState = await stateManager.getState()
        guard !wmState.displays.isEmpty else {
            throw RecordingError.targetResolutionFailed("no displays")
        }
        let regions = wmState.displays
            .compactMap(\.frame)
            .sorted(by: { $0.origin.x < $1.origin.x })
        return ResolvedTarget(label: "all", regions: regions)
    }
}

// MARK: - GridRecorder internals

// Resolved pre-capture state shared by both the fixed-duration and indefinite paths.
private struct RecordingSetup {
    let resolved: ResolvedTarget
    // Final destination path (may have .mov extension if ffmpeg was unavailable)
    let outPath: String
    // Possibly downgraded to "mov" if ffmpeg is unavailable
    let format: String
    let fps: Int
}

// State held on the actor while an indefinite recording is in flight.
// stop() reads this to complete the pipeline; cancel() uses it to terminate processes.
private struct PendingRecording {
    let target: ResolvedTarget
    let options: RecordingOptions
    // Final destination path
    let outPath: String
    // Possibly downgraded to "mov" if ffmpeg is unavailable
    let format: String
    let fps: Int
    // One path per captured region (pre-allocated before Tasks launch)
    let capturedFilePaths: [String]
    // Non-nil only in follow mode; stop() calls .stop() on this to get crop events
    let focusTracker: FocusTracker?
    // Wall clock when capture began; used to compute actual elapsed duration
    let startTime: Date
}

// MARK: - GridRecorder Actor

actor GridRecorder {
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager

    // All active screencapture processes (one per region for multi-region, or one for single/follow).
    // Populated via storeProcess() callbacks from captureRegion().
    // Used by stop() (SIGINT) and cancel() (SIGTERM).
    private var activeProcesses: [Process] = []

    // Non-nil while a recording is in flight (fixed-duration or indefinite).
    // The recording computed property derives from this.
    private var pendingRecording: PendingRecording? = nil

    init(gridState: GridState, gridConfig: GridConfig, stateManager: StateManager) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
    }

    // MARK: - Public API

    // Runs a fixed-duration recording from start to finish, returning when complete.
    // options.duration must be non-nil; for indefinite recordings use toggle().
    func record(target: RecordingTarget, options: RecordingOptions) async throws -> RecordingResult {
        guard let duration = options.duration else {
            throw RecordingError.captureFailed("duration required for record(); use toggle() for indefinite")
        }
        guard pendingRecording == nil else {
            throw RecordingError.alreadyRecording
        }

        let setup = try await prepareRecording(target: target, options: options)

        // Store minimal pending state so cancel() can reach the processes
        pendingRecording = PendingRecording(
            target: setup.resolved,
            options: options,
            outPath: setup.outPath,
            format: setup.format,
            fps: setup.fps,
            capturedFilePaths: [],
            focusTracker: nil,
            startTime: Date()
        )
        defer {
            pendingRecording = nil
            activeProcesses = []
            cleanup()
        }

        let capturedFile = try await executeCapturePhase(setup: setup, options: options, duration: duration)
        return try await executeConversionPhase(
            capturedFile: capturedFile,
            setup: setup,
            options: options,
            actualDuration: duration
        )
    }

    // Starts an indefinite recording in the background and returns immediately.
    // Call stop() or toggle() to end the recording and receive the result.
    func startRecording(target: RecordingTarget, options: RecordingOptions) async throws {
        guard pendingRecording == nil else {
            throw RecordingError.alreadyRecording
        }

        let setup = try await prepareRecording(target: target, options: options)

        let tracker: FocusTracker?
        let captureRegions: [CGRect]

        if options.follow {
            tracker = FocusTracker(gridState: gridState, gridConfig: gridConfig, stateManager: stateManager)
            // Capture full focused display for follow mode
            let wmState = await stateManager.getState()
            let display: DisplayState?
            if let activeUUID = wmState.metadata.activeDisplayUUID {
                display = wmState.displays.first(where: { $0.uuid == activeUUID }) ?? wmState.displays.first
            } else {
                display = wmState.displays.first
            }
            captureRegions = [display?.frame ?? .zero]
        } else {
            tracker = nil
            captureRegions = setup.resolved.regions
        }

        // Pre-allocate paths before launching Tasks to avoid a race between path
        // generation and pendingRecording storage
        let capturedPaths = captureRegions.map { _ in tempPath("recording", "mov") }

        pendingRecording = PendingRecording(
            target: setup.resolved,
            options: options,
            outPath: setup.outPath,
            format: setup.format,
            fps: setup.fps,
            capturedFilePaths: capturedPaths,
            focusTracker: tracker,
            startTime: Date()
        )

        // Launch one screencapture process per region; each Task suspends until SIGINT
        for (regionIndex, region) in captureRegions.enumerated() {
            let path = capturedPaths[regionIndex]
            let cursor = options.cursor
            Task { [weak self] in
                // Background task errors are intentionally not propagated here.
                // stop() will discover missing/partial files and throw at conversion time.
                try? await captureRegion(
                    region: region,
                    duration: nil,
                    cursor: cursor,
                    outPath: path,
                    onProcess: { proc in
                        // onProcess fires synchronously before captureRegion suspends;
                        // hop to actor to safely append to activeProcesses
                        Task { await self?.storeProcess(proc) }
                    }
                )
            }
        }

        jlog("record.start.indefinite", data: ["label": setup.resolved.label])
    }

    // Stops the active indefinite recording: sends SIGINT to all screencapture processes,
    // waits for them to exit, then runs the conversion pipeline and returns the result.
    // Throws if no recording is active.
    func stop() async throws -> RecordingResult {
        guard let pending = pendingRecording else {
            throw RecordingError.captureFailed("no active recording")
        }

        let startTime = pending.startTime
        let processesToStop = activeProcesses

        // Arm termination handlers BEFORE sending SIGINT to avoid a race where the
        // process exits between interrupt() and handler installation.
        let waiter = armProcessWaiter(processesToStop)

        // SIGINT tells screencapture to finalize the MOV container cleanly before exiting
        for proc in processesToStop {
            proc.interrupt()
        }

        // Wait for all processes to exit (handlers already armed)
        await waiter()

        // Compute actual elapsed wall-clock duration
        let elapsedSeconds = Int(Date().timeIntervalSince(startTime).rounded())

        // Stop focus tracker and collect events before clearing state
        let focusEvents = pending.focusTracker?.stop() ?? []

        // Clear actor state before pipeline so a concurrent toggle() call can proceed
        pendingRecording = nil
        activeProcesses = []

        // Post-capture pipeline: apply follow-mode crop, stitch multi-region, then convert
        let capturedFile: String

        if pending.options.follow {
            let rawFile = pending.capturedFilePaths[0]
            if !focusEvents.isEmpty {
                // Use actual elapsed duration so crop trim points are accurate
                let (filter, _, _) = buildCropFilter(
                    events: focusEvents,
                    recordingDuration: Double(elapsedSeconds)
                )
                let croppedFile = tempPath("cropped", "mov")
                try applyCropFilter(input: rawFile, output: croppedFile, filter: filter)
                try? FileManager.default.removeItem(atPath: rawFile)
                capturedFile = croppedFile
            } else {
                capturedFile = rawFile
            }
        } else if pending.capturedFilePaths.count == 1 {
            capturedFile = pending.capturedFilePaths[0]
        } else {
            // Multi-region: stitch all captures into one file
            let stitchedFile = tempPath("stitched", "mov")
            try stitchRecordings(
                inputs: pending.capturedFilePaths,
                output: stitchedFile,
                regions: pending.target.regions
            )
            for path in pending.capturedFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            capturedFile = stitchedFile
        }

        let setup = RecordingSetup(
            resolved: pending.target,
            outPath: pending.outPath,
            format: pending.format,
            fps: pending.fps
        )
        return try await executeConversionPhase(
            capturedFile: capturedFile,
            setup: setup,
            options: pending.options,
            actualDuration: elapsedSeconds
        )
    }

    // Toggles recording state: starts an indefinite recording if none is active (returns nil),
    // or stops the active recording and returns its result.
    func toggle(target: RecordingTarget, options: RecordingOptions) async throws -> RecordingResult? {
        if pendingRecording != nil {
            let result = try await stop()
            jlog("record.toggle.stop", data: ["duration": result.duration])
            return result
        } else {
            var indefiniteOptions = options
            // Ensure duration is nil so captureRegion omits -V (indefinite screencapture)
            indefiniteOptions.duration = nil
            try await startRecording(target: target, options: indefiniteOptions)
            jlog("record.toggle.start")
            return nil
        }
    }

    // Immediately terminates all active processes (SIGTERM — no MOV finalization).
    // Use for abort/error paths; for a clean stop use stop().
    func cancel() {
        for proc in activeProcesses {
            proc.terminate()
        }
        activeProcesses = []
        pendingRecording = nil
        jlog("record.cancel")
    }

    // True while a recording is in flight (fixed-duration or indefinite).
    var recording: Bool {
        pendingRecording != nil
    }

    // MARK: - Private helpers

    // Actor-isolated append called via Task hop from onProcess callback.
    // The callback fires in a non-actor context; hopping here keeps mutation safe.
    private func storeProcess(_ proc: Process) {
        activeProcesses.append(proc)
    }

    // Resolves target, checks ffmpeg, runs countdown, and returns a RecordingSetup.
    // Shared by record() and startRecording() to avoid duplicated setup logic.
    private func prepareRecording(target: RecordingTarget, options: RecordingOptions) async throws -> RecordingSetup {
        jlog("record.start", data: ["format": options.format, "duration": options.duration as Any])

        let resolved = try await resolveTarget(
            target: target,
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager
        )

        var outPath = options.output ?? generateOutputPath(options.outputDir, resolved.label, options.format)

        var format = options.format
        let needsFFmpeg = format != "mov" || resolved.regions.count > 1
        if needsFFmpeg && !ffmpegAvailable() {
            jlog("record.ffmpeg.missing")
            format = "mov"
            if let dotRange = outPath.range(of: ".", options: .backwards) {
                outPath = String(outPath[outPath.startIndex..<dotRange.lowerBound]) + ".mov"
            }
        }

        let fps = options.effectiveFPS

        if options.countdown > 0 {
            jlog("record.countdown", data: ["seconds": options.countdown])
            try await Task.sleep(for: .seconds(options.countdown))
        }

        return RecordingSetup(resolved: resolved, outPath: outPath, format: format, fps: fps)
    }

    // Runs the screencapture phase for fixed-duration recordings.
    // Handles follow mode, single-region, and multi-region (parallel) cases.
    // Returns the path of the captured file ready for conversion.
    private func executeCapturePhase(
        setup: RecordingSetup,
        options: RecordingOptions,
        duration: Int
    ) async throws -> String {
        var capturedFile: String

        if options.follow {
            let wmState = await stateManager.getState()
            let display: DisplayState?
            if let activeUUID = wmState.metadata.activeDisplayUUID {
                display = wmState.displays.first(where: { $0.uuid == activeUUID }) ?? wmState.displays.first
            } else {
                display = wmState.displays.first
            }
            let fullScreenRegion = display?.frame ?? .zero
            capturedFile = tempPath("recording", "mov")

            let tracker = FocusTracker(gridState: gridState, gridConfig: gridConfig, stateManager: stateManager)

            jlog("record.capture.follow")
            try await captureRegion(
                region: fullScreenRegion,
                duration: duration,
                cursor: options.cursor,
                outPath: capturedFile,
                onProcess: { [weak self] proc in Task { await self?.storeProcess(proc) } }
            )

            let focusEvents = tracker.stop()
            if !focusEvents.isEmpty {
                let (filter, _, _) = buildCropFilter(
                    events: focusEvents,
                    recordingDuration: Double(duration)
                )
                let croppedFile = tempPath("cropped", "mov")
                try applyCropFilter(input: capturedFile, output: croppedFile, filter: filter)
                try? FileManager.default.removeItem(atPath: capturedFile)
                capturedFile = croppedFile
            }

        } else if setup.resolved.regions.count == 1 {
            capturedFile = tempPath("recording", "mov")
            jlog("record.capture.single", data: ["label": setup.resolved.label])
            try await captureRegion(
                region: setup.resolved.regions[0],
                duration: duration,
                cursor: options.cursor,
                outPath: capturedFile,
                onProcess: { [weak self] proc in Task { await self?.storeProcess(proc) } }
            )

        } else {
            jlog("record.capture.multi", data: ["count": setup.resolved.regions.count])
            let regions = setup.resolved.regions
            let cursor = options.cursor
            let tmpFiles = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (regionIndex, region) in regions.enumerated() {
                    let path = tempPath("region-\(regionIndex)", "mov")
                    group.addTask { [weak self] in
                        try await captureRegion(
                            region: region,
                            duration: duration,
                            cursor: cursor,
                            outPath: path,
                            onProcess: { proc in Task { await self?.storeProcess(proc) } }
                        )
                        return (regionIndex, path)
                    }
                }
                var results = [(Int, String)]()
                for try await result in group {
                    results.append(result)
                }
                return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }

            capturedFile = tempPath("stitched", "mov")
            try stitchRecordings(inputs: tmpFiles, output: capturedFile, regions: setup.resolved.regions)
            for f in tmpFiles {
                try? FileManager.default.removeItem(atPath: f)
            }
        }

        return capturedFile
    }

    // Converts the captured MOV, moves it to the final destination, and returns a RecordingResult.
    // actualDuration is used in the result and for logging; for toggle mode this is elapsed seconds.
    private func executeConversionPhase(
        capturedFile: String,
        setup: RecordingSetup,
        options: RecordingOptions,
        actualDuration: Int
    ) async throws -> RecordingResult {
        if setup.format == "mov" {
            try FileManager.default.moveItem(atPath: capturedFile, toPath: setup.outPath)
        } else {
            try convertRecording(
                input: capturedFile,
                output: setup.outPath,
                format: setup.format,
                fps: setup.fps,
                width: options.width,
                quality: options.quality
            )
            try? FileManager.default.removeItem(atPath: capturedFile)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: setup.outPath)
        let size = (attrs[.size] as? Int64) ?? 0

        if options.open {
            let openProc = Process()
            openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProc.arguments = [setup.outPath]
            try? openProc.run()
        }

        jlog("record.done", data: [
            "path": setup.outPath,
            "format": setup.format,
            "size": size,
            "duration": actualDuration,
        ])

        return RecordingResult(
            filePath: setup.outPath,
            format: setup.format,
            size: size,
            duration: actualDuration
        )
    }

    // Arms termination handlers on all processes and returns an async closure that
    // resolves when every process has exited. Must be called BEFORE sending SIGINT
    // to avoid a race where a process exits before the handler is installed.
    private nonisolated func armProcessWaiter(_ processes: [Process]) -> (@Sendable () async -> Void) {
        let group = DispatchGroup()
        for proc in processes {
            group.enter()
            let existingHandler = proc.terminationHandler
            proc.terminationHandler = { p in
                existingHandler?(p)
                group.leave()
            }
        }
        return {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) {
                    continuation.resume()
                }
            }
        }
    }

    private func cleanup() {
        // Remove any lingering temp files matching "thegrid-*" in temp dir
        let tmpDir = NSTemporaryDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
        for file in files {
            if file.hasPrefix("thegrid-") {
                try? fm.removeItem(atPath: (tmpDir as NSString).appendingPathComponent(file))
            }
        }
    }

    private func tempPath(_ prefix: String, _ ext: String) -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1_000_000)
        return NSTemporaryDirectory() + "thegrid-\(prefix)-\(ts).\(ext)"
    }

    private func generateOutputPath(_ dir: String, _ label: String, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ts = formatter.string(from: Date())
        let name = "recording-\(label)-\(ts).\(format)"
        let outDir: String
        if !dir.isEmpty {
            outDir = dir
        } else {
            outDir = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        }
        return (outDir as NSString).appendingPathComponent(name)
    }
}
