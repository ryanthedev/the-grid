# GridViewer Phase 1 Pseudocode: Static Image Viewer

## File: grid-server/Sources/GridViewer/main.swift

```
// MARK: - Imports
import AppKit, UniformTypeIdentifiers, ImageIO, AVFoundation, AVKit

// MARK: - Logging
// Copy vlog() pattern from GridTerminal
// Log file: ~/.local/state/thegrid/grid-viewer.json
// Event prefix: viewer.*

// MARK: - PID File
// Path: ~/.local/state/thegrid/grid-viewer.pid
// Write on start, cleanup on terminate

// MARK: - Content Type Detection

ENUM ContentType:
    case staticImage
    case animatedGIF
    case video

FUNCTION detectContentType(url: URL) -> ContentType?:
    guard let uttype = UTType(filenameExtension: url.pathExtension) else: return nil
    if uttype conforms to .gif: return .animatedGIF
    if uttype conforms to .movie or .video: return .video
    if uttype conforms to .image: return .staticImage
    return nil

// MARK: - Window Sizing

FUNCTION fitWindowToContent(mediaSize: CGSize) -> NSRect:
    screen = NSScreen.main?.visibleFrame ?? default
    maxW = screen.width * 0.9
    maxH = screen.height * 0.9
    scale = min(1.0, min(maxW / mediaSize.width, maxH / mediaSize.height))
    winSize = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
    // Center on screen
    origin = CGPoint(
        x: screen.midX - winSize.width / 2,
        y: screen.midY - winSize.height / 2
    )
    return NSRect(origin: origin, size: winSize)

// MARK: - Viewer Window

CLASS ViewerWindow: NSWindow:
    let contentType: ContentType
    var mediaView: NSView  // will be swapped per content type

    INIT(url: URL, contentType: ContentType):
        // Load image to get dimensions
        guard let image = NSImage(contentsOf: url) else: error
        let frame = fitWindowToContent(image.size)

        super.init(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], ...)

        // Window properties
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.95)
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Create NSImageView
        let imageView = NSImageView(frame: contentView!.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        contentView!.addSubview(imageView)

        vlog("viewer.load", data: ["file": url.path, "type": "image",
             "size": "\(Int(image.size.width))x\(Int(image.size.height))"])

    // Keyboard handling
    OVERRIDE keyDown(event):
        switch event.keyCode:
            case 53 (ESC): close(); NSApp.terminate(nil)
            case 12 (Q): close(); NSApp.terminate(nil)
            default: super.keyDown(event)

    OVERRIDE canBecomeKey -> true
    OVERRIDE canBecomeMain -> false

// MARK: - App Delegate

CLASS AppDelegate: NSObject, NSApplicationDelegate:
    var window: ViewerWindow?
    let fileURL: URL

    INIT(fileURL: URL):
        self.fileURL = fileURL

    applicationDidFinishLaunching:
        // Detect content type
        guard let contentType = detectContentType(fileURL) else:
            fputs("error: unsupported file type: \(fileURL.pathExtension)\n", stderr)
            NSApp.terminate(nil)
            return

        // Phase 1: only handle static images
        guard contentType == .staticImage else:
            fputs("error: only static images supported in this version\n", stderr)
            NSApp.terminate(nil)
            return

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window = ViewerWindow(url: fileURL, contentType: contentType)
        window?.makeKeyAndOrderFront(nil)

        vlog("viewer.ready")

    applicationWillTerminate:
        cleanupPidFile()

// MARK: - Main

// Parse command line: first arg is file path
guard CommandLine.arguments.count > 1 else:
    fputs("Usage: grid-viewer <file>\n", stderr)
    exit(1)

let filePath = CommandLine.arguments[1]
let fileURL = URL(fileURLWithPath: filePath)

guard FileManager.default.fileExists(atPath: filePath) else:
    fputs("error: file not found: \(filePath)\n", stderr)
    exit(1)

// Write PID file
writePidFile()

vlog("viewer.init", data: ["file": filePath])

let app = NSApplication.shared
let delegate = AppDelegate(fileURL: fileURL)
app.delegate = delegate
app.run()
```

## File: grid-server/Package.swift

```
ADD to products array:
    .executable(name: "grid-viewer", targets: ["GridViewer"])

ADD to targets array:
    .executableTarget(name: "GridViewer", dependencies: [], path: "Sources/GridViewer")
```

## File: Makefile

```
ADD target:
    viewer:
        cd grid-server && swift build --product grid-viewer

ADD to dev dependency list
```

## Design Decisions

1. **backgroundColor = NSColor.black.withAlphaComponent(0.95)** - Dark background for letterboxing, slight transparency
2. **NSImageView.scaleProportionallyUpOrDown** - Fills window maintaining aspect ratio
3. **ContentType enum defined now** - Even though Phase 1 only handles images, the enum is ready for Phase 2/3
4. **fileURL passed to AppDelegate** - Not global, clean ownership
5. **Exit on unsupported type** - Phase 1 rejects video/GIF with clear error message
