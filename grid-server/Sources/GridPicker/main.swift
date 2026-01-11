//
// grid-picker
//
// Standalone input picker with clean CLI API
//
// Usage:
//   grid-picker [--prompt "text"] [--width N] [--height N]
//
// Output (stdout):
//   {"text": "user input", "cancelled": false}
//   {"text": "", "cancelled": true}
//
// Exit codes:
//   0 = submitted (Enter)
//   1 = cancelled (ESC, Close, focus loss)
//

import AppKit

// MARK: - Configuration

struct PickerConfig {
    var prompt: String = ""
    var width: CGFloat = 400
    var height: CGFloat = 56

    static func parse(_ args: [String]) -> PickerConfig {
        var config = PickerConfig()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--prompt":
                if i + 1 < args.count {
                    config.prompt = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--width":
                if i + 1 < args.count, let w = Double(args[i + 1]) {
                    config.width = CGFloat(w)
                    i += 2
                } else {
                    i += 1
                }
            case "--height":
                if i + 1 < args.count, let h = Double(args[i + 1]) {
                    config.height = CGFloat(h)
                    i += 2
                } else {
                    i += 1
                }
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                i += 1
            }
        }
        return config
    }
}

func printUsage() {
    let usage = """
    grid-picker - Standalone input picker

    Usage:
      grid-picker [options]

    Options:
      --prompt TEXT   Prompt text shown before input
      --width N       Window width in pixels (default: 400)
      --height N      Window height in pixels (default: 56)
      --help, -h      Show this help

    Output (JSON to stdout):
      {"text": "user input", "cancelled": false}

    Exit codes:
      0 = submitted (Enter)
      1 = cancelled (ESC, Close, or focus loss)
    """
    fputs(usage + "\n", stderr)
}

// MARK: - Result Handling

enum PickerResult {
    case submitted(String)
    case cancelled

    var exitCode: Int32 {
        switch self {
        case .submitted: return 0
        case .cancelled: return 1
        }
    }

    var json: String {
        switch self {
        case .submitted(let text):
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "{\"text\": \"\(escaped)\", \"cancelled\": false}"
        case .cancelled:
            return "{\"text\": \"\", \"cancelled\": true}"
        }
    }
}

func finish(_ result: PickerResult) -> Never {
    print(result.json)
    exit(result.exitCode)
}

// MARK: - Colors (Catppuccin Mocha)

struct Colors {
    static let background = NSColor(red: 0.118, green: 0.118, blue: 0.180, alpha: 0.95)
    static let inputBackground = NSColor(red: 0.192, green: 0.200, blue: 0.267, alpha: 1)
    static let text = NSColor(red: 0.804, green: 0.839, blue: 0.957, alpha: 1)
    static let placeholder = NSColor(red: 0.424, green: 0.439, blue: 0.525, alpha: 1)
    static let border = NSColor(red: 0.345, green: 0.357, blue: 0.439, alpha: 1)
    static let prompt = NSColor(red: 0.537, green: 0.706, blue: 0.980, alpha: 1)
}

// MARK: - Window

class PickerWindow: NSWindow {
    private let textField: NSTextField
    private let promptLabel: NSLabel
    private let closeButton: NSButton
    private let config: PickerConfig

    init(config: PickerConfig) {
        self.config = config

        // Create text field
        textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textField.textColor = Colors.text
        textField.placeholderString = "Type here..."
        textField.placeholderAttributedString = NSAttributedString(
            string: "Type here...",
            attributes: [
                .foregroundColor: Colors.placeholder,
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            ]
        )

        // Create prompt label
        promptLabel = NSLabel()
        promptLabel.stringValue = config.prompt
        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        promptLabel.textColor = Colors.prompt
        promptLabel.isHidden = config.prompt.isEmpty

        // Create close button
        closeButton = NSButton(title: "✕", target: nil, action: nil)
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = Colors.placeholder

        // Calculate position - center on screen
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let origin = NSPoint(
            x: screen.frame.midX - config.width / 2,
            y: screen.frame.midY - config.height / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: CGSize(width: config.width, height: config.height)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContentView()
        setupLayout()
        setupActions()
    }

    private func setupWindow() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        acceptsMouseMovedEvents = true
    }

    private func setupContentView() {
        let bgView = BackgroundView()
        contentView = bgView
    }

    private func setupLayout() {
        guard let bgView = contentView else { return }

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        bgView.addSubview(promptLabel)
        bgView.addSubview(textField)
        bgView.addSubview(closeButton)

        let padding: CGFloat = 16

        if config.prompt.isEmpty {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
                textField.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
                textField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            ])
        } else {
            NSLayoutConstraint.activate([
                promptLabel.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
                promptLabel.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),

                textField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
                textField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            ])
        }

        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            closeButton.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func setupActions() {
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        textField.delegate = self
    }

    @objc private func closeClicked() {
        finish(.cancelled)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finish(.cancelled)
        }
        super.keyDown(with: event)
    }

    func submit() {
        finish(.submitted(textField.stringValue))
    }
}

extension PickerWindow: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            finish(.cancelled)
            return true
        }
        return false
    }
}

// MARK: - NSLabel (simple label helper)

class NSLabel: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// MARK: - Background View

class BackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)

        Colors.background.setFill()
        path.fill()

        Colors.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PickerWindow?
    let config: PickerConfig

    init(config: PickerConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window = PickerWindow(config: config)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView?.subviews.first { $0 is NSTextField })

        // Watch for focus loss
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        finish(.cancelled)
    }
}

// MARK: - Main

let config = PickerConfig.parse(CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
