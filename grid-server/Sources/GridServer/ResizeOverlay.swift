//
// ResizeOverlay.swift
// GridServer
//
// Visual indicator showing resize mode is active.
// Non-interactive NSWindow that displays "RESIZE: CELL" or "RESIZE: WINDOW".
//

import Foundation
import AppKit

/// Visual overlay for resize mode
class ResizeOverlay {
    // MARK: - Properties

    private var window: NSWindow?
    private var textField: NSTextField?

    /// Size of the overlay
    private let overlaySize = NSSize(width: 160, height: 36)

    /// Corner offset from screen edge
    private let cornerOffset: CGFloat = 20

    // MARK: - Initialization

    init() {
    }

    // MARK: - Public Methods

    /// Show the overlay with the specified mode
    /// - Parameter mode: Either "RESIZE: CELL" or "RESIZE: WINDOW"
    func show(mode: String) {
        // Must run on main thread for UI
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(mode: mode)
            }
            return
        }

        // Create window if needed
        if window == nil {
            createWindow()
        }

        // Update text
        textField?.stringValue = mode

        // Position in top-right corner of main screen
        positionWindow()

        // Show the window
        window?.orderFront(nil)

        Task { JSONLogger.shared.log("resize.overlay.show", data: ["mode": mode]) }
    }

    /// Hide the overlay
    func hide() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.hide()
            }
            return
        }

        window?.orderOut(nil)
        Task { JSONLogger.shared.log("resize.overlay.hide", data: [:]) }
    }

    /// Update the overlay position (e.g., to follow cursor)
    func updatePosition(near point: CGPoint) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updatePosition(near: point)
            }
            return
        }

        guard let window = window else { return }

        // Position near cursor but offset so it doesn't obscure
        let offset: CGFloat = 20
        var newOrigin = CGPoint(
            x: point.x + offset,
            y: point.y - overlaySize.height - offset
        )

        // Keep on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame

            // Clamp to screen bounds
            newOrigin.x = max(screenFrame.minX, min(newOrigin.x, screenFrame.maxX - overlaySize.width))
            newOrigin.y = max(screenFrame.minY, min(newOrigin.y, screenFrame.maxY - overlaySize.height))
        }

        window.setFrameOrigin(newOrigin)
    }

    // MARK: - Private Methods

    private func createWindow() {
        // Create a borderless, floating window
        let contentRect = NSRect(origin: .zero, size: overlaySize)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true  // Click-through
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Create content view with rounded background
        let contentView = NSView(frame: contentRect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        contentView.layer?.cornerRadius = 8

        // Create text field
        let textField = NSTextField(frame: NSRect(
            x: 12,
            y: 8,
            width: overlaySize.width - 24,
            height: overlaySize.height - 16
        ))
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.textColor = .white
        textField.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        textField.alignment = .center
        textField.stringValue = "RESIZE MODE"

        contentView.addSubview(textField)
        window.contentView = contentView

        self.window = window
        self.textField = textField
    }

    private func positionWindow() {
        guard let window = window, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame

        // Top-right corner
        let origin = CGPoint(
            x: screenFrame.maxX - overlaySize.width - cornerOffset,
            y: screenFrame.maxY - overlaySize.height - cornerOffset
        )

        window.setFrameOrigin(origin)
    }
}
