import AppKit
import SwiftTerm

// MARK: - Logging

private let logFilePath: String = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        ?? (NSHomeDirectory() + "/.local/state")
    let dir = stateHome + "/thegrid"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/grid-terminal.json"
}()

func tlog(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
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

// MARK: - Colors

struct Colors {
    static let background = NSColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 0.98)
    static let border = NSColor(red: 0.251, green: 0.251, blue: 0.251, alpha: 1)
    static let text = NSColor(red: 0.749, green: 0.749, blue: 0.749, alpha: 1)
    // Cursor color - bright blue accent
    static let cursor = NSColor(red: 0.0, green: 0.749, blue: 1.0, alpha: 1)
}

struct GhosttyTheme {
    var background: NSColor?
    var foreground: NSColor?
    var cursorColor: NSColor?
    var selectionBg: NSColor?
    var fontFamily: String?
    var fontSize: CGFloat?
    var backgroundOpacity: CGFloat?
    var palette: [Int: (UInt16, UInt16, UInt16)]

    init() {
        palette = [:]
    }
}

func nsColorFromHex(_ hex: String) -> NSColor? {
    var cleaned = hex
    if cleaned.hasPrefix("#") {
        cleaned = String(cleaned.dropFirst())
    }

    guard cleaned.count == 6 else {
        return nil
    }

    guard let value = UInt32(cleaned, radix: 16) else {
        return nil
    }

    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0

    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
}

func loadGhosttyTheme() -> GhosttyTheme? {
    let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        ?? (NSHomeDirectory() + "/.config")
    let configPath = configHome + "/ghostty/config"

    guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        tlog("term.theme", msg: "ghostty config not found")
        return nil
    }

    var theme = GhosttyTheme()

    for line in contents.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }

        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)

        switch key {
        case "background":
            theme.background = nsColorFromHex(value)

        case "foreground":
            theme.foreground = nsColorFromHex(value)

        case "cursor-color":
            theme.cursorColor = nsColorFromHex(value)

        case "selection-background":
            theme.selectionBg = nsColorFromHex(value)

        case "font-family":
            var cleaned = value
            if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            theme.fontFamily = cleaned

        case "font-size":
            if let sizeValue = Double(value) {
                theme.fontSize = CGFloat(sizeValue)
            }

        case "background-opacity":
            if let opacityValue = Double(value) {
                theme.backgroundOpacity = CGFloat(opacityValue)
            }

        case "palette":
            let paletteParts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard paletteParts.count == 2 else {
                continue
            }

            guard let index = Int(paletteParts[0].trimmingCharacters(in: .whitespaces)) else {
                continue
            }

            let hexValue = paletteParts[1].trimmingCharacters(in: .whitespaces)

            var hex = hexValue
            if hex.hasPrefix("#") {
                hex = String(hex.dropFirst())
            }

            guard hex.count == 6 else {
                continue
            }

            guard let rgb = UInt32(hex, radix: 16) else {
                continue
            }

            let r8 = UInt8((rgb >> 16) & 0xFF)
            let g8 = UInt8((rgb >> 8) & 0xFF)
            let b8 = UInt8(rgb & 0xFF)

            let r16 = UInt16(r8) * 257
            let g16 = UInt16(g8) * 257
            let b16 = UInt16(b8) * 257

            theme.palette[index] = (r16, g16, b16)

        default:
            continue
        }
    }

    tlog("term.theme", msg: "loaded ghostty theme", data: ["path": configPath])
    return theme
}

// MARK: - Utilities

let pidFilePath: String = {
    let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        ?? (NSHomeDirectory() + "/.local/state")
    return stateHome + "/thegrid/grid-terminal.pid"
}()

func checkSingleInstance() {
    let fm = FileManager.default
    let dir = (pidFilePath as NSString).deletingLastPathComponent
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

    if let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
       let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
        if kill(pid, 0) == 0 {
            tlog("term.toggle", msg: "sending SIGUSR1", data: ["pid": Int(pid)])
            kill(pid, SIGUSR1)
            exit(0)
        }
    }

    try? "\(ProcessInfo.processInfo.processIdentifier)"
        .write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    tlog("term.start", data: ["pid": Int(ProcessInfo.processInfo.processIdentifier)])
}

func cleanupPidFile() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
}

func findTmux() -> String? {
    let commonPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    let fm = FileManager.default
    for path in commonPaths {
        if fm.isExecutableFile(atPath: path) {
            return path
        }
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    task.arguments = ["tmux"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()

    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    } catch {
        return nil
    }
}

// MARK: - Background View

class BackgroundView: NSView {
    var fillColor: NSColor = Colors.background

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        if let layer = self.layer {
            layer.cornerRadius = 6
            layer.masksToBounds = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
            xRadius: 6,
            yRadius: 6
        )

        fillColor.setFill()
        path.fill()

        Colors.border.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - Terminal Window

class TerminalWindow: NSWindow {
    private(set) var terminalView: LocalProcessTerminalView!
    private let tmuxPath: String
    private var theme: GhosttyTheme?
    private var previousApp: NSRunningApplication?

    init(tmuxPath: String) {
        self.tmuxPath = tmuxPath

        guard let screen = NSScreen.main else {
            fatalError("No screen available")
        }

        let screenFrame = screen.frame
        let winWidth = screenFrame.width * 0.8
        let winHeight = screenFrame.height * 0.6

        let origin = NSPoint(
            x: screenFrame.midX - winWidth / 2,
            y: screenFrame.midY - winHeight / 2
        )

        let contentRect = NSRect(
            origin: origin,
            size: CGSize(width: winWidth, height: winHeight)
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        setupWindow()
    }

    private func setupWindow() {
        self.theme = loadGhosttyTheme()

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true

        self.acceptsMouseMovedEvents = true
        self.setFrameAutosaveName("GridTerminalWindow")

        let bgView = BackgroundView(frame: self.contentLayoutRect)

        if let theme = self.theme,
           let bg = theme.background,
           let opacity = theme.backgroundOpacity {
            bgView.fillColor = NSColor(
                srgbRed: bg.redComponent,
                green: bg.greenComponent,
                blue: bg.blueComponent,
                alpha: opacity
            )
        }

        self.contentView = bgView

        setupTerminalView(in: bgView)
        setupKeyMonitor()
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isKeyWindow else { return event }

            // Shift+Enter sends ESC CR (matches Ghostty keybind for Claude CLI multiline)
            if event.modifierFlags.contains(.shift) && event.keyCode == 0x24 {
                tlog("term.key", msg: "shift+enter")
                self.terminalView.send(txt: "\u{1b}\r")
                return nil
            }

            return event
        }
    }

    private func setupTerminalView(in containerView: NSView) {
        let inset: CGFloat = 4
        let termFrame = containerView.bounds.insetBy(dx: inset, dy: inset)

        terminalView = LocalProcessTerminalView(frame: termFrame)
        terminalView.autoresizingMask = [.width, .height]

        if let theme = self.theme {
            if let bg = theme.background {
                terminalView.nativeBackgroundColor = NSColor(
                    srgbRed: bg.redComponent,
                    green: bg.greenComponent,
                    blue: bg.blueComponent,
                    alpha: 1.0
                )
            } else {
                terminalView.nativeBackgroundColor = NSColor(
                    red: 0.071, green: 0.071, blue: 0.071, alpha: 1.0
                )
            }

            if let fg = theme.foreground {
                terminalView.nativeForegroundColor = fg
            } else {
                terminalView.nativeForegroundColor = Colors.text
            }

            if let cursor = theme.cursorColor {
                terminalView.caretColor = cursor
            } else {
                terminalView.caretColor = Colors.cursor
            }

            if let selBg = theme.selectionBg {
                terminalView.selectedTextBackgroundColor = selBg
            }

            var font: NSFont?
            if let family = theme.fontFamily, let size = theme.fontSize {
                font = NSFont(name: family, size: size)
            } else if let family = theme.fontFamily {
                font = NSFont(name: family, size: 15)
            } else if let size = theme.fontSize {
                font = NSFont(name: "BerkeleyMono Nerd Font", size: size)
            }

            if let f = font {
                terminalView.font = f
            } else {
                if let defaultFont = NSFont(name: "BerkeleyMono Nerd Font", size: 15) {
                    terminalView.font = defaultFont
                } else {
                    terminalView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                }
            }

            if !theme.palette.isEmpty && theme.palette.count == 16 {
                var colors: [SwiftTerm.Color] = []
                for i in 0..<16 {
                    if let (r16, g16, b16) = theme.palette[i] {
                        colors.append(SwiftTerm.Color(red: r16, green: g16, blue: b16))
                    } else {
                        colors = []
                        break
                    }
                }

                if colors.count == 16 {
                    terminalView.installColors(colors)
                }
            }
        } else {
            terminalView.nativeBackgroundColor = NSColor(
                red: 0.071, green: 0.071, blue: 0.071, alpha: 1.0
            )
            terminalView.nativeForegroundColor = Colors.text
            terminalView.caretColor = Colors.cursor

            if let font = NSFont(name: "BerkeleyMono Nerd Font", size: 15) {
                terminalView.font = font
            } else {
                terminalView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            }
        }

        containerView.addSubview(terminalView)

        terminalView.startProcess(
            executable: tmuxPath,
            args: ["new-session", "-A", "-s", "grid-scratch"]
        )
    }

    func recenterOnCurrentScreen() {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let screenFrame = screen.frame
        let winWidth = screenFrame.width * 0.8
        let winHeight = screenFrame.height * 0.6

        let origin = NSPoint(
            x: screenFrame.midX - winWidth / 2,
            y: screenFrame.midY - winHeight / 2
        )

        setFrame(NSRect(origin: origin, size: CGSize(width: winWidth, height: winHeight)), display: true)
    }

    func toggle() {
        if isVisible {
            tlog("term.hide")
            orderOut(nil)
            previousApp?.activate()
            previousApp = nil
        } else {
            previousApp = NSWorkspace.shared.frontmostApplication
            moveToActiveScreen()
            tlog("term.show")
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func moveToActiveScreen() {
        guard let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        // Already on this screen — keep position
        if let currentScreen = screen, currentScreen == targetScreen { return }

        // Center on the target screen, preserving current size
        let winSize = frame.size
        let screenFrame = targetScreen.frame
        let origin = NSPoint(
            x: screenFrame.midX - winSize.width / 2,
            y: screenFrame.midY - winSize.height / 2
        )
        setFrameOrigin(origin)
    }

    func respawnTmux() {
        terminalView.startProcess(
            executable: tmuxPath,
            args: ["new-session", "-A", "-s", "grid-scratch"]
        )
    }

    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: TerminalWindow?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let tmuxPath = findTmux() else {
            fputs("error: tmux not found\nInstall via: brew install tmux\n", stderr)
            NSApp.terminate(nil)
            return
        }

        tlog("term.init", data: ["tmux": tmuxPath])

        setupMainMenu()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window = TerminalWindow(tmuxPath: tmuxPath)
        window?.terminalView.processDelegate = self
        window?.makeKeyAndOrderFront(nil)

        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            tlog("term.signal", msg: "SIGUSR1 received")
            self?.window?.toggle()
        }
        src.resume()
        self.signalSource = src

        tlog("term.ready")
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Edit menu — enables Cmd+C/V/A via responder chain
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupPidFile()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Handled automatically by SwiftTerm
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // No visible title bar
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Not tracking directory changes
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        tlog("term.proc.exit", data: ["code": Int(exitCode ?? -1)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.window?.respawnTmux()
        }
    }
}

// MARK: - Main

checkSingleInstance()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
