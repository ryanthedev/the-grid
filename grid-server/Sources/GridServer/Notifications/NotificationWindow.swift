//
// NotificationWindow.swift
// GridServer
//
// Floating toast notification window.
// Displays title, body, buttons, and optional text input.
//

import Foundation
import AppKit

/// Delegate for notification window events
protocol NotificationWindowDelegate: AnyObject {
    func notificationWindow(_ window: NotificationWindow, didClickButton button: String)
    func notificationWindow(_ window: NotificationWindow, didSubmitText text: String)
}

/// Floating notification toast window
class NotificationWindow: NSWindow {
    // MARK: - Properties

    let notificationId: String
    weak var notificationDelegate: NotificationWindowDelegate?

    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField?
    private var buttonStack: NSStackView?
    private var textField: NSTextField?

    private let padding: CGFloat = 16
    private let buttonHeight: CGFloat = 28
    private let textFieldHeight: CGFloat = 24
    private let maxTextLength: Int

    // MARK: - Initialization

    init(
        notificationId: String,
        title: String,
        body: String?,
        buttons: [String]?,
        hasTextInput: Bool,
        textMaxLength: Int,
        position: NotificationPosition
    ) {
        self.notificationId = notificationId
        self.maxTextLength = textMaxLength

        // Calculate initial size (will adjust after layout)
        let initialSize = NSSize(width: 300, height: 100)
        let contentRect = NSRect(origin: .zero, size: initialSize)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Build UI
        setupContentView()
        setupTitle(title)
        if let body = body, !body.isEmpty {
            setupBody(body)
        }
        if hasTextInput {
            setupTextField()
        }
        if let buttons = buttons, !buttons.isEmpty {
            setupButtons(buttons)
        }

        // Calculate final size and position
        layoutAndPosition(position)

        Task {
            await EventLog.shared.log("notif.window.create", ["id": notificationId])
        }
    }

    // MARK: - Setup Methods

    private func setupContentView() {
        let contentView = NSView(frame: self.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        contentView.layer?.cornerRadius = 12
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        self.contentView = contentView
    }

    private func setupTitle(_ title: String) {
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(titleLabel)
    }

    private func setupBody(_ body: String) {
        bodyLabel = NSTextField(labelWithString: body)
        bodyLabel?.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        bodyLabel?.textColor = NSColor(white: 0.8, alpha: 1.0)
        bodyLabel?.alignment = .left
        bodyLabel?.lineBreakMode = .byWordWrapping
        bodyLabel?.maximumNumberOfLines = 3
        bodyLabel?.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(bodyLabel!)
    }

    private func setupTextField() {
        textField = NSTextField()
        textField?.placeholderString = "Enter text..."
        textField?.font = NSFont.systemFont(ofSize: 12)
        textField?.textColor = .white
        textField?.backgroundColor = NSColor(white: 0.2, alpha: 1.0)
        textField?.isBordered = false
        textField?.focusRingType = .none
        textField?.wantsLayer = true
        textField?.layer?.cornerRadius = 4
        textField?.translatesAutoresizingMaskIntoConstraints = false
        textField?.target = self
        textField?.action = #selector(textFieldDidSubmit)
        contentView?.addSubview(textField!)
    }

    private func setupButtons(_ buttons: [String]) {
        buttonStack = NSStackView()
        buttonStack?.orientation = .horizontal
        buttonStack?.spacing = 8
        buttonStack?.distribution = .fillEqually
        buttonStack?.translatesAutoresizingMaskIntoConstraints = false

        for (index, buttonTitle) in buttons.enumerated() {
            let button = NSButton(title: buttonTitle, target: self, action: #selector(buttonClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)

            // Style first button as primary
            if index == 0 {
                button.keyEquivalent = "\r"
            }

            buttonStack?.addArrangedSubview(button)
        }

        contentView?.addSubview(buttonStack!)
    }

    private func layoutAndPosition(_ position: NotificationPosition) {
        guard let contentView = contentView else { return }

        let width: CGFloat = 280
        var currentY: CGFloat = padding

        // Layout from bottom to top

        // Buttons at bottom
        if let buttonStack = buttonStack {
            buttonStack.frame = NSRect(
                x: padding,
                y: currentY,
                width: width - 2 * padding,
                height: buttonHeight
            )
            currentY += buttonHeight + 12
        }

        // Text field
        if let textField = textField {
            textField.frame = NSRect(
                x: padding,
                y: currentY,
                width: width - 2 * padding,
                height: textFieldHeight
            )
            currentY += textFieldHeight + 12
        }

        // Body
        if let bodyLabel = bodyLabel {
            let bodyWidth = width - 2 * padding
            let bodySize = bodyLabel.sizeThatFits(NSSize(width: bodyWidth, height: 60))
            bodyLabel.frame = NSRect(
                x: padding,
                y: currentY,
                width: bodyWidth,
                height: min(bodySize.height, 60)
            )
            currentY += min(bodySize.height, 60) + 8
        }

        // Title at top
        titleLabel.frame = NSRect(
            x: padding,
            y: currentY,
            width: width - 2 * padding,
            height: 20
        )
        currentY += 20 + padding

        // Set final window size
        let finalHeight = currentY
        let windowSize = NSSize(width: width, height: finalHeight)

        // Calculate position based on anchor
        let origin = calculateOrigin(
            cellBounds: position.bounds,
            anchor: position.anchor,
            windowSize: windowSize
        )

        self.setFrame(NSRect(origin: origin, size: windowSize), display: true)
        contentView.frame = NSRect(origin: .zero, size: windowSize)
    }

    private func calculateOrigin(
        cellBounds: CGRect,
        anchor: NotificationAnchor,
        windowSize: NSSize
    ) -> CGPoint {
        let margin: CGFloat = 12

        switch anchor {
        case .topRight:
            return CGPoint(
                x: cellBounds.maxX - windowSize.width - margin,
                y: cellBounds.maxY - windowSize.height - margin
            )
        case .topLeft:
            return CGPoint(
                x: cellBounds.minX + margin,
                y: cellBounds.maxY - windowSize.height - margin
            )
        case .bottomRight:
            return CGPoint(
                x: cellBounds.maxX - windowSize.width - margin,
                y: cellBounds.minY + margin
            )
        case .bottomLeft:
            return CGPoint(
                x: cellBounds.minX + margin,
                y: cellBounds.minY + margin
            )
        case .center:
            return CGPoint(
                x: cellBounds.midX - windowSize.width / 2,
                y: cellBounds.midY - windowSize.height / 2
            )
        }
    }

    // MARK: - Actions

    @objc private func buttonClicked(_ sender: NSButton) {
        let buttonTitle = sender.title
        Task {
            await EventLog.shared.log("notif.click", ["id": notificationId, "button": buttonTitle])
        }
        notificationDelegate?.notificationWindow(self, didClickButton: buttonTitle)
    }

    @objc private func textFieldDidSubmit() {
        guard let text = textField?.stringValue else { return }

        // Sanitize and limit text
        let sanitized = sanitizeText(text)

        Task {
            await EventLog.shared.log("notif.text", ["id": notificationId, "textLen": sanitized.count])
        }
        notificationDelegate?.notificationWindow(self, didSubmitText: sanitized)
    }

    // MARK: - Text Sanitization

    private func sanitizeText(_ text: String) -> String {
        // Limit length
        var result = String(text.prefix(maxTextLength))

        // Remove control characters (except newlines, tabs)
        result = result.unicodeScalars.filter { scalar in
            // Allow printable characters and common whitespace
            scalar.value >= 32 || scalar == "\n" || scalar == "\t"
        }.map { String($0) }.joined()

        return result
    }

    // MARK: - Public Methods

    func show() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show()
            }
            return
        }

        self.orderFront(nil)
        self.makeKeyAndOrderFront(nil)

        // Focus text field if present
        if let textField = textField {
            self.makeFirstResponder(textField)
        }

        Task {
            await EventLog.shared.log("notif.show", ["id": notificationId])
        }
    }

    func dismiss() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.dismiss()
            }
            return
        }

        self.orderOut(nil)
        Task {
            await EventLog.shared.log("notif.dismiss", ["id": notificationId])
        }
    }
}
