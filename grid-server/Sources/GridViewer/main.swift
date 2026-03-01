import AppKit
import AVFoundation
import AVKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Logging

private let logFilePath: String = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        ?? (NSHomeDirectory() + "/.local/state")
    let dir = stateHome + "/thegrid"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/grid-viewer.json"
}()

func vlog(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
    var parts: [String] = []
    parts.append("\"ev\":\"\(ev)\"")
    if let msg = msg { parts.append("\"msg\":\"\(msg)\"") }
    if let data = data,
       let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
       let jsonStr = String(data: jsonData, encoding: .utf8) {
        parts.append("\"data\":\(jsonStr)")
    }
    parts.append("\"ts\":\(Int(Date().timeIntervalSince1970))")
    let line = "{" + parts.joined(separator: ",") + "}\n"
    if let lineData = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: logFilePath) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: lineData)
        } else {
            FileManager.default.createFile(atPath: logFilePath, contents: lineData)
        }
    }
}

// MARK: - PID File

let pidFilePath: String = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        ?? (NSHomeDirectory() + "/.local/state")
    return stateHome + "/thegrid/grid-viewer.pid"
}()

func writePidFile() {
    let dir = (pidFilePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "\(ProcessInfo.processInfo.processIdentifier)"
        .write(toFile: pidFilePath, atomically: true, encoding: .utf8)
}

func cleanupPidFile() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
}

// MARK: - Content Type Detection

enum ContentType {
    case staticImage
    case animatedGIF
    case video
}

func detectContentType(url: URL) -> ContentType? {
    guard let uttype = UTType(filenameExtension: url.pathExtension) else { return nil }
    if uttype.conforms(to: .gif) { return .animatedGIF }
    if uttype.conforms(to: .movie) || uttype.conforms(to: .video) { return .video }
    if uttype.conforms(to: .image) { return .staticImage }
    return nil
}

// MARK: - Window Sizing

func fitWindowToContent(mediaSize: CGSize) -> NSRect {
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let maxW = screen.width * 0.9
    let maxH = screen.height * 0.9
    let scale = min(1.0, min(maxW / mediaSize.width, maxH / mediaSize.height))
    let winSize = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
    let origin = CGPoint(
        x: screen.midX - winSize.width / 2,
        y: screen.midY - winSize.height / 2
    )
    return NSRect(origin: origin, size: winSize)
}

// MARK: - Video Helpers

// Synchronous size lookup required before NSWindow super.init; async API not usable there.
// swiftlint:disable:next deprecated_in_future
func videoNaturalSize(asset: AVAsset) -> CGSize {
    return asset.tracks(withMediaType: .video).first?.naturalSize
        ?? CGSize(width: 1280, height: 720)
}

// MARK: - Video Content View

class VideoContentView: NSView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer, frame: NSRect) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor.black
        super.init(frame: frame)
        wantsLayer = true
        layer!.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

// MARK: - GIF Content View

private func gifFrameDelay(source: CGImageSource, index: Int) -> TimeInterval {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
    let gifProps = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
    let delay = gifProps?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
        ?? gifProps?[kCGImagePropertyGIFDelayTime as String] as? Double
        ?? 0.1
    // GIF spec: delays < 0.02s should be treated as 0.1s
    return delay < 0.02 ? 0.1 : delay
}

class GIFContentView: NSView {
    private struct GIFFrame {
        let image: NSImage
        let delay: TimeInterval
    }

    private let imageView: NSImageView
    private var frames: [GIFFrame] = []
    private var currentFrame: Int = 0
    private(set) var isPaused: Bool = false
    private var timer: DispatchSourceTimer?

    init(url: URL, frame: NSRect) {
        imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]

        super.init(frame: frame)

        addSubview(imageView)

        // Extract all frames from the GIF
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            vlog("viewer.gif.error", msg: "failed to create image source", data: ["file": url.path])
            return
        }

        let frameCount = CGImageSourceGetCount(source)
        for i in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let nsImage = NSImage(cgImage: cgImage, size: size)
            let delay = gifFrameDelay(source: source, index: i)
            frames.append(GIFFrame(image: nsImage, delay: delay))
        }

        guard !frames.isEmpty else {
            vlog("viewer.gif.error", msg: "no frames extracted", data: ["file": url.path])
            return
        }

        // Show first frame immediately before timer fires
        imageView.image = frames[0].image

        startTimer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Create and arm a new timer starting at the current frame's delay
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        timer = t
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Advance to next frame (wrapping)
            self.currentFrame = (self.currentFrame + 1) % self.frames.count
            self.imageView.image = self.frames[self.currentFrame].image
            // Reschedule with the NEW frame's delay
            t.schedule(deadline: .now() + self.frames[self.currentFrame].delay)
        }
        // First fire: use the current frame's delay so it shows for its full duration
        t.schedule(deadline: .now() + frames[currentFrame].delay)
        t.resume()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    func togglePause() {
        if isPaused {
            isPaused = false
            startTimer()
        } else {
            isPaused = true
            cancelTimer()
        }
    }

    func stepForward() {
        if !isPaused {
            isPaused = true
            cancelTimer()
        }
        guard !frames.isEmpty else { return }
        currentFrame = (currentFrame + 1) % frames.count
        imageView.image = frames[currentFrame].image
    }

    func stepBackward() {
        if !isPaused {
            isPaused = true
            cancelTimer()
        }
        guard !frames.isEmpty else { return }
        currentFrame = (currentFrame - 1 + frames.count) % frames.count
        imageView.image = frames[currentFrame].image
    }
}

// MARK: - Viewer Window

class ViewerWindow: NSWindow {
    let contentType: ContentType
    var player: AVPlayer?
    var gifView: GIFContentView?

    init(url: URL, contentType: ContentType) {
        self.contentType = contentType

        let frame: NSRect
        switch contentType {
        case .staticImage:
            guard let image = NSImage(contentsOf: url) else {
                fatalError("Failed to load image: \(url.path)")
            }
            frame = fitWindowToContent(mediaSize: image.size)
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            setupWindowStyle()
            let imageView = NSImageView(frame: self.contentView!.bounds)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            self.contentView!.addSubview(imageView)
            vlog("viewer.load", data: [
                "file": url.path,
                "type": "image",
                "size": "\(Int(image.size.width))x\(Int(image.size.height))"
            ])

        case .video:
            let asset = AVAsset(url: url)
            let naturalSize = videoNaturalSize(asset: asset)
            frame = fitWindowToContent(mediaSize: naturalSize)
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            setupWindowStyle()
            let avPlayer = AVPlayer(url: url)
            self.player = avPlayer
            let videoView = VideoContentView(player: avPlayer, frame: self.contentView!.bounds)
            videoView.autoresizingMask = [.width, .height]
            self.contentView!.addSubview(videoView)
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { [weak avPlayer] _ in
                avPlayer?.seek(to: .zero)
                avPlayer?.play()
            }
            avPlayer.play()
            vlog("viewer.load", data: [
                "file": url.path,
                "type": "video",
                "size": "\(Int(naturalSize.width))x\(Int(naturalSize.height))"
            ])

        case .animatedGIF:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let firstCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fatalError("Failed to load GIF: \(url.path)")
            }
            let mediaSize = CGSize(width: firstCGImage.width, height: firstCGImage.height)
            frame = fitWindowToContent(mediaSize: mediaSize)
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            setupWindowStyle()
            let gif = GIFContentView(url: url, frame: self.contentView!.bounds)
            gif.autoresizingMask = [.width, .height]
            self.contentView!.addSubview(gif)
            self.gifView = gif
            let frameCount = CGImageSourceGetCount(source)
            vlog("viewer.load", data: [
                "file": url.path,
                "type": "gif",
                "frames": frameCount,
                "size": "\(Int(mediaSize.width))x\(Int(mediaSize.height))"
            ])
        }
    }

    private func setupWindowStyle() {
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.95)
        self.hasShadow = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        // ESC
        case 53:
            close()
            NSApp.terminate(nil)
        // Q
        case 12:
            close()
            NSApp.terminate(nil)
        // Space: toggle play/pause
        case 49:
            if let gif = gifView {
                gif.togglePause()
            } else if let p = player {
                if p.rate > 0 { p.pause() } else { p.play() }
            }
        // Left arrow: seek backward 5s (video) or step back one frame (GIF)
        case 123:
            if let gif = gifView {
                gif.stepBackward()
            } else if let p = player {
                let current = p.currentTime()
                let target = CMTimeSubtract(current, CMTimeMakeWithSeconds(5, preferredTimescale: 600))
                p.seek(to: CMTimeMaximum(target, .zero))
            }
        // Right arrow: seek forward 5s (video) or step forward one frame (GIF)
        case 124:
            if let gif = gifView {
                gif.stepForward()
            } else if let p = player {
                let current = p.currentTime()
                let target = CMTimeAdd(current, CMTimeMakeWithSeconds(5, preferredTimescale: 600))
                p.seek(to: target)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: ViewerWindow?
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let contentType = detectContentType(url: fileURL) else {
            fputs("error: unsupported file type: \(fileURL.pathExtension)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window = ViewerWindow(url: fileURL, contentType: contentType)
        window?.makeKeyAndOrderFront(nil)

        vlog("viewer.ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupPidFile()
    }
}

// MARK: - Main

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: grid-viewer <file>\n", stderr)
    exit(1)
}

let filePath = CommandLine.arguments[1]
let fileURL = URL(fileURLWithPath: filePath)

guard FileManager.default.fileExists(atPath: filePath) else {
    fputs("error: file not found: \(filePath)\n", stderr)
    exit(1)
}

writePidFile()

vlog("viewer.init", data: ["file": filePath])

let app = NSApplication.shared
let delegate = AppDelegate(fileURL: fileURL)
app.delegate = delegate
app.run()
