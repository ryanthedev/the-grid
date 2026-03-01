import AppKit
import AVFoundation
import AVKit
import Darwin
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

// MARK: - Socket Path

let socketPath: String = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        ?? (NSHomeDirectory() + "/.local/state")
    return stateHome + "/thegrid/grid-viewer.sock"
}()

// MARK: - Socket Address Helper (top-level for shared use)

func makeSockAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // Copy path bytes into the fixed-size sun_path tuple
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { cstr in
            UnsafeMutableRawPointer(ptr).copyMemory(from: cstr, byteCount: min(strlen(cstr) + 1, 104))
        }
    }
    return addr
}

// MARK: - Send to Existing Viewer

func sendToExistingViewer(filePath: String) -> Bool {
    // Open a Unix domain socket and send the file path to the running instance
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }

    var addr = makeSockAddr(socketPath)
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { return false }

    // Send the file path terminated by newline; no response expected
    let data = (filePath + "\n").data(using: .utf8)!
    _ = data.withUnsafeBytes { send(sock, $0.baseAddress, data.count, 0) }
    return true
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

func makePlayerView(player: AVPlayer, frame: NSRect) -> AVPlayerView {
    let pv = AVPlayerView(frame: frame)
    pv.player = player
    pv.controlsStyle = .floating
    pv.autoresizingMask = [.width, .height]
    return pv
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

    func stopAnimation() {
        cancelTimer()
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

// MARK: - Viewer Socket

class ViewerSocket {
    private let socketPath: String
    private var serverSocket: Int32?
    var onFileReceived: ((String) -> Void)?

    init(path: String) {
        self.socketPath = path
    }

    func start() throws {
        // Remove stale socket file from a previous run
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "ViewerSocket", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(errno)"])
        }
        serverSocket = fd

        // Bind to path
        var addr = makeSockAddr(socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            serverSocket = nil
            throw NSError(domain: "ViewerSocket", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(errno)"])
        }

        // Listen for connections (backlog of 5 is sufficient for single-instance use)
        guard listen(fd, 5) == 0 else {
            close(fd)
            serverSocket = nil
            throw NSError(domain: "ViewerSocket", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed: \(errno)"])
        }

        // Start accepting connections on a background queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }

        vlog("viewer.socket.start", data: ["path": socketPath])
    }

    private func acceptLoop() {
        guard let fd = serverSocket else { return }

        while true {
            // Block until a client connects
            let clientFd = accept(fd, nil, nil)
            guard clientFd >= 0 else {
                // accept() fails when the server socket is closed during stop()
                break
            }

            // Read newline-terminated file path (4KB buffer is sufficient for any path)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var received = ""
            var done = false

            while !done {
                let n = recv(clientFd, &buffer, buffer.count, 0)
                guard n > 0 else { break }
                let chunk = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
                received += chunk
                if received.contains("\n") { done = true }
            }

            close(clientFd)

            // Extract the path before the newline
            let filePath = received.components(separatedBy: "\n").first ?? ""
            guard !filePath.isEmpty else { continue }

            // Deliver to callback on main queue
            let path = filePath
            DispatchQueue.main.async { [weak self] in
                self?.onFileReceived?(path)
            }
        }
    }

    func stop() {
        // Close the server socket; this causes accept() to return -1 and exit the loop
        if let fd = serverSocket {
            close(fd)
            serverSocket = nil
        }
        // Remove the socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        vlog("viewer.socket.stop")
    }
}

// MARK: - Viewer Window

class ViewerWindow: NSWindow {
    var player: AVPlayer?
    var gifView: GIFContentView?

    init(url: URL, contentType: ContentType) {
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
            self.contentView!.addSubview(makePlayerView(player: avPlayer, frame: self.contentView!.bounds))
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

    // Load a new file into the existing window, replacing current content
    func loadFile(url: URL) {
        guard let contentType = detectContentType(url: url) else {
            vlog("viewer.load.error", msg: "unsupported file type", data: ["file": url.path])
            return
        }

        // Stop existing media before replacing content
        if let p = player {
            p.pause()
            // Remove loop observer for the old item
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: p.currentItem)
            player = nil
        }
        if let gif = gifView {
            gif.stopAnimation()
            gifView = nil
        }

        // Remove all existing subviews from the content view
        contentView?.subviews.forEach { $0.removeFromSuperview() }

        // Build new content view and resize window based on content type
        switch contentType {
        case .staticImage:
            guard let image = NSImage(contentsOf: url) else {
                vlog("viewer.load.error", msg: "failed to load image", data: ["file": url.path])
                return
            }
            let newFrame = fitWindowToContent(mediaSize: image.size)
            setFrame(newFrame, display: true)
            let imageView = NSImageView(frame: contentView!.bounds)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            contentView!.addSubview(imageView)
            vlog("viewer.load", data: [
                "file": url.path,
                "type": "image",
                "size": "\(Int(image.size.width))x\(Int(image.size.height))"
            ])

        case .video:
            let asset = AVAsset(url: url)
            let naturalSize = videoNaturalSize(asset: asset)
            let newFrame = fitWindowToContent(mediaSize: naturalSize)
            setFrame(newFrame, display: true)
            let avPlayer = AVPlayer(url: url)
            self.player = avPlayer
            contentView!.addSubview(makePlayerView(player: avPlayer, frame: contentView!.bounds))
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
                vlog("viewer.load.error", msg: "failed to load GIF", data: ["file": url.path])
                return
            }
            let mediaSize = CGSize(width: firstCGImage.width, height: firstCGImage.height)
            let newFrame = fitWindowToContent(mediaSize: mediaSize)
            setFrame(newFrame, display: true)
            let gif = GIFContentView(url: url, frame: contentView!.bounds)
            gif.autoresizingMask = [.width, .height]
            contentView!.addSubview(gif)
            self.gifView = gif
            let frameCount = CGImageSourceGetCount(source)
            vlog("viewer.load", data: [
                "file": url.path,
                "type": "gif",
                "frames": frameCount,
                "size": "\(Int(mediaSize.width))x\(Int(mediaSize.height))"
            ])
        }

        // Bring the window to front
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupWindowStyle() {
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.95)
        self.hasShadow = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
    }

    // Borderless windows need explicit drag handling
    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
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
    var viewerSocket: ViewerSocket?
    let fileURL: URL
    let isPrimary: Bool

    init(fileURL: URL, isPrimary: Bool) {
        self.fileURL = fileURL
        self.isPrimary = isPrimary
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

        // Only the primary instance listens for file paths from future invocations
        if isPrimary {
            let sock = ViewerSocket(path: socketPath)
            sock.onFileReceived = { [weak self] filePath in
                guard let self = self, let win = self.window else { return }
                let url = URL(fileURLWithPath: filePath)
                guard FileManager.default.fileExists(atPath: filePath) else {
                    vlog("viewer.load.error", msg: "file not found", data: ["file": filePath])
                    return
                }
                win.loadFile(url: url)
            }
            do {
                try sock.start()
                viewerSocket = sock
            } catch {
                vlog("viewer.socket.error", msg: "failed to start socket", data: ["err": error.localizedDescription])
            }
        }

        vlog("viewer.ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewerSocket?.stop()
        if isPrimary {
            cleanupPidFile()
        }
    }
}

// MARK: - Main

// Parse arguments: [--new] <file>
var newInstance = false
var fileArg: String?

for arg in CommandLine.arguments.dropFirst() {
    if arg == "--new" {
        newInstance = true
    } else if fileArg == nil {
        fileArg = arg
    }
}

guard let filePath = fileArg else {
    fputs("Usage: grid-viewer [--new] <file>\n", stderr)
    exit(1)
}

let fileURL = URL(fileURLWithPath: filePath)

guard FileManager.default.fileExists(atPath: filePath) else {
    fputs("error: file not found: \(filePath)\n", stderr)
    exit(1)
}

// Check if an existing instance is already running via PID file
let existingPid: pid_t? = newInstance ? nil : {
    guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
          let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    // kill(pid, 0) returns 0 if the process is alive, -1 otherwise
    return kill(pid, 0) == 0 ? pid : nil
}()

if existingPid != nil {
    // Existing instance is alive — try to send the file path to it
    if sendToExistingViewer(filePath: filePath) {
        // Successfully handed off to existing instance; this process can exit
        exit(0)
    }
    // Socket send failed (e.g., socket not yet ready or stale); fall through to normal startup
    vlog("viewer.handoff.failed", msg: "could not send to existing instance, starting new")
}

// Only claim PID/socket ownership for the primary instance
if !newInstance {
    writePidFile()
}

vlog("viewer.init", data: ["file": filePath, "new": newInstance])

let app = NSApplication.shared
let delegate = AppDelegate(fileURL: fileURL, isPrimary: !newInstance)
app.delegate = delegate

// Ignore default signal disposition so DispatchSource handlers fire instead.
// Must be installed after delegate is created so handlers can reference it.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

// Hold references so sources are not deallocated before app exits
let termSource: DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    cleanupPidFile()
    delegate.viewerSocket?.stop()
    NSApp.terminate(nil)
}
termSource.resume()

let intSource: DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler {
    cleanupPidFile()
    delegate.viewerSocket?.stop()
    NSApp.terminate(nil)
}
intSource.resume()

app.run()
