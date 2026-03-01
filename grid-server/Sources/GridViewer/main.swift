import AppKit
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

// MARK: - Viewer Window

class ViewerWindow: NSWindow {
    let contentType: ContentType

    init(url: URL, contentType: ContentType) {
        self.contentType = contentType

        guard let image = NSImage(contentsOf: url) else {
            fatalError("Failed to load image: \(url.path)")
        }

        let frame = fitWindowToContent(mediaSize: image.size)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.95)
        self.hasShadow = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true

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

        // Phase 1: only handle static images
        guard contentType == .staticImage else {
            fputs("error: only static images supported in this version\n", stderr)
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
