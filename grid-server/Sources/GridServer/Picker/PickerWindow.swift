//
// PickerWindow.swift
// GridServer
//
// Borderless floating picker window — ported from GridPicker/main.swift
// Removes PickerConfig dependency, adds spinner, uses onResult callback
//

import AppKit

class PickerWindow: NSWindow {
    private let textField: NSTextField
    private let closeButton: NSButton
    private let emptyLabel: NSLabel
    // Spinner shown while async sources are loading
    private let spinner: NSProgressIndicator

    // State and list view (always list mode)
    private var state: PickerState
    private var listView: PickerListView
    private var listViewHeightConstraint: NSLayoutConstraint?

    // Layout constants
    private static let inputHeight: CGFloat = 68
    private static let listPadding: CGFloat = 8
    private static let windowWidth: CGFloat = 800

    /// Callback invoked when the user selects an item or cancels
    var onResult: ((PickerResult) -> Void)?

    init() {
        // Create text field (no border, no background, no focus ring)
        textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = PickerFonts.mono(size: 19)
        textField.textColor = PickerColors.text

        // Create close button
        closeButton = NSButton(title: "✕", target: nil, action: nil)
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = PickerColors.placeholder

        // Create empty state label
        emptyLabel = NSLabel()
        emptyLabel.stringValue = "No matches"
        emptyLabel.font = PickerFonts.mono(size: 17)
        emptyLabel.textColor = PickerColors.placeholder
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // Create spinner for loading state
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Start with empty state — items arrive via appendItems from async sources
        state = PickerState(items: [])

        // Calculate initial window size — always full list height
        let initialHeight = Self.inputHeight + PickerState.maxListHeight + Self.listPadding

        // Center on screen containing mouse cursor
        let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first!
        let origin = NSPoint(
            x: targetScreen.frame.midX - Self.windowWidth / 2,
            y: targetScreen.frame.midY - initialHeight / 2
        )

        // Create list view before super.init
        listView = PickerListView(state: state)

        super.init(
            contentRect: NSRect(origin: origin, size: CGSize(width: Self.windowWidth, height: initialHeight)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContentView()
        setupLayout()
        setupActions()
        setupStateObserver()
    }

    // MARK: - Setup

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
        contentView = PickerBackgroundView()
    }

    private func setupLayout() {
        guard let bgView = contentView else { return }

        textField.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false

        bgView.addSubview(textField)
        bgView.addSubview(spinner)
        bgView.addSubview(closeButton)
        bgView.addSubview(emptyLabel)
        bgView.addSubview(listView)

        let padding: CGFloat = 16

        // Input row: textField → spinner → closeButton
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
            textField.topAnchor.constraint(equalTo: bgView.topAnchor, constant: padding),
            textField.heightAnchor.constraint(equalToConstant: Self.inputHeight - padding * 2),
            textField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),

            spinner.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            closeButton.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            closeButton.topAnchor.constraint(equalTo: bgView.topAnchor, constant: padding),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: Self.inputHeight - padding * 2),
        ])

        // Empty label (shown when no matches)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
            emptyLabel.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            emptyLabel.topAnchor.constraint(equalTo: bgView.topAnchor, constant: Self.inputHeight),
            emptyLabel.heightAnchor.constraint(equalToConstant: ListItemView.itemHeight),
        ])

        // List view (always present — always list mode)
        let listHeight = listView.requiredHeight
        let heightConstraint = listView.heightAnchor.constraint(equalToConstant: listHeight)
        self.listViewHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: bgView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: bgView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: bgView.topAnchor, constant: Self.inputHeight),
            heightConstraint,
        ])

        listView.refresh()
    }

    private func setupActions() {
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        textField.delegate = self
    }

    private func setupStateObserver() {
        state.onStateChange = { [weak self] in
            self?.handleStateChange()
        }
    }

    // MARK: - State Updates

    private func handleStateChange() {
        listView.refresh()
        updateWindowSize()
        updateEmptyLabel()
    }

    private func updateWindowSize() {
        // Update list view height constraint for content layout
        // Window frame stays fixed — no shifting on filter
        listViewHeightConstraint?.constant = listView.requiredHeight
        contentView?.needsDisplay = true
    }

    private func updateEmptyLabel() {
        emptyLabel.isHidden = !(state.hasItems && state.filteredResults.isEmpty)
    }

    // MARK: - Key Handling

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // ESC — cancel
        if event.keyCode == 53 {
            onResult?(.cancelled)
            return
        }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Down arrow or Ctrl-n
        if keyCode == 125 || (keyCode == 45 && modifiers == .control) {
            state.moveSelection(1)
            return
        }

        // Up arrow or Ctrl-p
        if keyCode == 126 || (keyCode == 35 && modifiers == .control) {
            state.moveSelection(-1)
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Actions

    @objc private func closeClicked() {
        onResult?(.cancelled)
    }

    private func submit() {
        if let selectedItem = state.selectedItem {
            onResult?(.selected(selectedItem))
        } else {
            onResult?(.cancelled)
        }
    }

    // MARK: - Public API for PickerManager

    /// Focus the search text field
    func focusInput() {
        makeFirstResponder(textField)
    }

    /// Recenter the window on the screen where the mouse cursor is
    func recenterOnMouseScreen() {
        guard let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let winSize = frame.size
        let screenFrame = targetScreen.frame
        setFrameOrigin(NSPoint(
            x: screenFrame.midX - winSize.width / 2,
            y: screenFrame.midY - winSize.height / 2
        ))
    }

    /// Reset for a new show cycle — clears text and state, recenters
    func resetForNewShow() {
        textField.stringValue = ""
        state.resetWithItems([])
        recenterOnMouseScreen()
    }

    /// Expose state for PickerManager to call appendItems
    func getState() -> PickerState {
        return state
    }

    /// Show or hide the loading spinner
    func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension PickerWindow: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            onResult?(.cancelled)
            return true
        }
        if commandSelector == #selector(moveDown(_:)) {
            state.moveSelection(1)
            return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            state.moveSelection(-1)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        state.updateQuery(textField.stringValue)
    }
}
