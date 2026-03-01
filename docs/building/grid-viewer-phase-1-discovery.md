# GridViewer Phase 1 Discovery: Static Image Viewer

## Patterns Extracted

### Logging (from GridTerminal)
```swift
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
```

### PID File (from GridTerminal)
```swift
let pidFilePath: String = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        ?? (NSHomeDirectory() + "/.local/state")
    return stateHome + "/thegrid/grid-viewer.pid"
}()

// Write PID on start
try? "\(ProcessInfo.processInfo.processIdentifier)"
    .write(toFile: pidFilePath, atomically: true, encoding: .utf8)

// Cleanup
func cleanupPidFile() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
}
```

### Window Setup (from GridTerminal)
```swift
super.init(
    contentRect: rect,
    styleMask: [.borderless, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
self.level = .floating
self.collectionBehavior = [.canJoinAllSpaces, .transient]
self.isOpaque = false
self.backgroundColor = .clear
self.hasShadow = true
self.titleVisibility = .hidden
self.titlebarAppearsTransparent = true

override var canBecomeKey: Bool { true }
override var canBecomeMain: Bool { false }
```

### AppDelegate (from GridTerminal)
```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: ViewerWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window = ViewerWindow(...)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupPidFile()
    }
}
```

### Procedural Main (from GridTerminal)
```swift
let filePath = CommandLine.arguments.dropFirst().first
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

### Package.swift Addition
```swift
.executable(name: "grid-viewer", targets: ["GridViewer"])
// ...
.executableTarget(name: "GridViewer", dependencies: [], path: "Sources/GridViewer")
```

### Makefile Addition
```makefile
viewer:
	@echo "Building grid-viewer..."
	@cd grid-server && swift build --product grid-viewer
```

## Key Notes
- Event prefix: `viewer.*` (viewer.init, viewer.load, viewer.error, viewer.close)
- No external dependencies
- Use UTType from UniformTypeIdentifiers for content detection
- Fit-to-content: cap at 90% screen, maintain aspect ratio, center
- Phase 1: no single-instance reuse yet (just PID file write for later)
