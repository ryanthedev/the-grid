//
// TestPanel.swift
// GridServer
//
// Minimal test: NSPanel that receives keyboard input.
// Triggered via BFD @test command.
//

import AppKit

class TestPanel: NSPanel {
    static let shared = TestPanel()

    private let textField: NSTextField

    private init() {
        textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        textField.textColor = .white
        textField.placeholderString = "Type here..."
        textField.translatesAutoresizingMaskIntoConstraints = false

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let width: CGFloat = 600
        let height: CGFloat = 50
        let origin = NSPoint(
            x: screen.frame.midX - width / 2,
            y: screen.frame.midY - height / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Panel config
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // Background view
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        bg.layer?.cornerRadius = 10
        bg.translatesAutoresizingMaskIntoConstraints = false

        contentView = NSView(frame: .zero)
        contentView!.addSubview(bg)
        bg.addSubview(textField)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            bg.topAnchor.constraint(equalTo: contentView!.topAnchor),
            bg.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),

            textField.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            toggle()
            return
        }
        super.keyDown(with: event)
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
            jlog("test.panel.hide")
        } else {
            textField.stringValue = ""
            if let screen = NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main {
                let f = frame
                setFrameOrigin(NSPoint(
                    x: screen.frame.midX - f.width / 2,
                    y: screen.frame.midY - f.height / 2
                ))
            }
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            makeFirstResponder(textField)
            jlog("test.panel.show")
        }
    }
}
