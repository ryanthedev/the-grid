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
    var duration: Int = 5
    var output: String? = nil
    var outputDir: String = ""
    var format: String = "gif"
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
        let currentDisplay = wmState.displays.first(where: { $0.isMain == true }) ?? wmState.displays.first
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

func buildCaptureArgs(region: CGRect, duration: Int, cursor: Bool, outPath: String) -> [String] {
    var args = ["-v"]
    args += ["-V", "\(duration)"]
    if cursor {
        args.append("-C")
    }
    args += ["-R", "\(Int(region.origin.x)),\(Int(region.origin.y)),\(Int(region.width)),\(Int(region.height))"]
    args.append(outPath)
    return args
}

func captureRegion(region: CGRect, duration: Int, cursor: Bool, outPath: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = buildCaptureArgs(region: region, duration: duration, cursor: cursor, outPath: outPath)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()

    // Wait for completion using continuation
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(throwing: RecordingError.captureFailed(output))
            } else {
                continuation.resume()
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
        let currentDisplay = wmState.displays.first(where: { $0.isMain == true }) ?? wmState.displays.first
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
            // Current display
            let current = wmState.displays.first(where: { $0.isMain == true }) ?? wmState.displays[0]
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

// MARK: - GridRecorder Actor

actor GridRecorder {
    private let gridState: GridState
    private let gridConfig: GridConfig
    private let stateManager: StateManager
    private var activeProcess: Process?
    private var isActive: Bool = false

    init(gridState: GridState, gridConfig: GridConfig, stateManager: StateManager) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
    }

    func record(target: RecordingTarget, options: RecordingOptions) async throws -> RecordingResult {
        guard !isActive else {
            throw RecordingError.alreadyRecording
        }
        isActive = true
        defer {
            isActive = false
            cleanup()
        }

        jlog("record.start", data: ["format": options.format, "duration": options.duration])

        // Resolve target to pixel bounds
        let resolved = try await resolveTarget(
            target: target,
            gridState: gridState,
            gridConfig: gridConfig,
            stateManager: stateManager
        )

        // Determine output path
        var outPath = options.output ?? generateOutputPath(options.outputDir, resolved.label, options.format)

        // Check ffmpeg requirement
        var format = options.format
        let needsFFmpeg = format != "mov" || resolved.regions.count > 1
        if needsFFmpeg && !ffmpegAvailable() {
            jlog("record.ffmpeg.missing")
            format = "mov"
            // Adjust extension in outPath
            if let dotRange = outPath.range(of: ".", options: .backwards) {
                outPath = String(outPath[outPath.startIndex..<dotRange.lowerBound]) + ".mov"
            }
        }

        let fps = options.effectiveFPS

        // Countdown (if > 0)
        if options.countdown > 0 {
            jlog("record.countdown", data: ["seconds": options.countdown])
            try await Task.sleep(for: .seconds(options.countdown))
        }

        // Capture phase
        var capturedFile: String

        if options.follow {
            // Follow mode: capture full screen, track focus changes
            let wmState = await stateManager.getState()
            let display = wmState.displays.first(where: { $0.isMain == true }) ?? wmState.displays.first
            let fullScreenRegion = display?.frame ?? .zero
            capturedFile = tempPath("recording", "mov")

            // Start focus tracker
            let tracker = FocusTracker(
                gridState: gridState,
                gridConfig: gridConfig,
                stateManager: stateManager
            )

            // Capture full screen
            jlog("record.capture.follow")
            try await captureRegion(
                region: fullScreenRegion,
                duration: options.duration,
                cursor: options.cursor,
                outPath: capturedFile
            )

            // Stop tracking, get events
            let focusEvents = tracker.stop()

            // Apply crop filter if we got focus events
            if !focusEvents.isEmpty {
                let (filter, _, _) = buildCropFilter(events: focusEvents, recordingDuration: Double(options.duration))
                let croppedFile = tempPath("cropped", "mov")
                try applyCropFilter(input: capturedFile, output: croppedFile, filter: filter)
                try? FileManager.default.removeItem(atPath: capturedFile)
                capturedFile = croppedFile
            }

        } else if resolved.regions.count == 1 {
            // Single region capture
            capturedFile = tempPath("recording", "mov")
            jlog("record.capture.single", data: ["label": resolved.label])
            try await captureRegion(
                region: resolved.regions[0],
                duration: options.duration,
                cursor: options.cursor,
                outPath: capturedFile
            )

        } else {
            // Multi-region: capture in parallel, then stitch
            jlog("record.capture.multi", data: ["count": resolved.regions.count])
            let regions = resolved.regions
            let duration = options.duration
            let cursor = options.cursor
            let tmpFiles = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (i, region) in regions.enumerated() {
                    let path = tempPath("region-\(i)", "mov")
                    group.addTask {
                        try await captureRegion(
                            region: region,
                            duration: duration,
                            cursor: cursor,
                            outPath: path
                        )
                        return (i, path)
                    }
                }
                var results = [(Int, String)]()
                for try await result in group {
                    results.append(result)
                }
                return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }

            capturedFile = tempPath("stitched", "mov")
            try stitchRecordings(inputs: tmpFiles, output: capturedFile, regions: resolved.regions)

            // Cleanup temp files
            for f in tmpFiles {
                try? FileManager.default.removeItem(atPath: f)
            }
        }

        // Convert phase
        if format == "mov" {
            try FileManager.default.moveItem(atPath: capturedFile, toPath: outPath)
        } else {
            try convertRecording(
                input: capturedFile,
                output: outPath,
                format: format,
                fps: fps,
                width: options.width,
                quality: options.quality
            )
            // Cleanup captured file after conversion
            try? FileManager.default.removeItem(atPath: capturedFile)
        }

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: outPath)
        let size = (attrs[.size] as? Int64) ?? 0

        // Open if requested
        if options.open {
            let openProc = Process()
            openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProc.arguments = [outPath]
            try? openProc.run()
        }

        jlog("record.done", data: ["path": outPath, "format": format, "size": size])

        return RecordingResult(filePath: outPath, format: format, size: size, duration: options.duration)
    }

    func cancel() {
        activeProcess?.terminate()
        isActive = false
        jlog("record.cancel")
    }

    var recording: Bool {
        isActive
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
        if !dir.isEmpty {
            return (dir as NSString).appendingPathComponent(name)
        }
        return name
    }
}
