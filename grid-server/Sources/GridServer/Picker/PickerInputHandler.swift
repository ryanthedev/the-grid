//
// PickerInputHandler.swift
// GridServer
//
// Keyboard and mouse input handling for the picker
//

import Foundation
import CoreGraphics
import AppKit

/// Key codes for keyboard events
enum KeyCode: UInt16 {
    case escape = 53
    case returnKey = 36
    case keypadEnter = 76
    case delete = 51
    case forwardDelete = 117
    case upArrow = 126
    case downArrow = 125
    case leftArrow = 123
    case rightArrow = 124
    case pageUp = 116
    case pageDown = 121
    // Letter keys (for ctrl combos)
    case a = 0
    case e = 14
    case j = 38
    case k = 40
    case n = 45
    case p = 35
    case u = 32
    case w = 13
}

/// Protocol for receiving picker input events
protocol PickerInputDelegate: AnyObject {
    /// Called when the query text changes
    func queryChanged(_ query: String, cursorPosition: Int)

    /// Called when selection should move (-1 = up, +1 = down, count = how many steps)
    func selectionMoved(_ direction: Int, count: Int)

    /// Called when user confirms selection (Enter)
    func selectionConfirmed()

    /// Called when user cancels (Escape)
    func pickerCancelled()

    /// Called when user clicks on an item at the given index
    func itemClicked(at index: Int)

    /// Called when user scrolls
    func scrolled(by delta: Int)
}

/// Handles keyboard and mouse input for the picker
@MainActor
class PickerInputHandler {
    weak var delegate: PickerInputDelegate?

    private var keyboardMonitor: Any?
    private var localKeyboardMonitor: Any?
    private var mouseClickMonitor: Any?
    private var scrollMonitor: Any?

    /// Current query text
    private(set) var query: String = ""

    /// Cursor position in query
    private(set) var cursorPosition: Int = 0

    /// Picker window bounds for hit testing
    var pickerBounds: CGRect = .zero

    /// Item height for click calculation
    var itemHeight: CGFloat = 32

    /// Max visible items
    var maxVisibleItems: Int = 10

    /// Input height for click calculation
    var inputHeight: CGFloat = 40

    /// Padding for click calculation
    var padding: CGFloat = 8

    init() {}

    deinit {
        // NSEvent.removeMonitor is thread-safe, so we can call cleanup from deinit
        cleanupMonitors()
    }

    /// Remove all monitors (thread-safe, can be called from deinit)
    private nonisolated func cleanupMonitors() {
        // Capture monitor references for thread-safe removal
        // Note: NSEvent.removeMonitor is documented as thread-safe
        MainActor.assumeIsolated {
            if let monitor = keyboardMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = localKeyboardMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = mouseClickMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    /// Start capturing input events
    func start() {
        guard keyboardMonitor == nil else { return }

        // Global keyboard monitor
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
        }

        // Local keyboard monitor (for when our app is focused)
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if self?.handleKeyDown(event) == true {
                return nil  // Consume event
            }
            return event
        }

        // Mouse click monitor
        mouseClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleMouseClick(event)
        }

        // Scroll wheel monitor
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.handleScroll(event)
        }

        JSONLogger.shared.log("pkr.input.start", data: [:])
    }

    /// Stop capturing input events
    func stop() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        if let monitor = localKeyboardMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyboardMonitor = nil
        }
        if let monitor = mouseClickMonitor {
            NSEvent.removeMonitor(monitor)
            mouseClickMonitor = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }

        JSONLogger.shared.log("pkr.input.stop", data: [:])
    }

    /// Reset the input state
    func reset() {
        query = ""
        cursorPosition = 0
    }

    // MARK: - Keyboard Handling

    /// Handle key down event
    /// - Returns: true if event was consumed
    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape - cancel
        if keyCode == KeyCode.escape.rawValue {
            delegate?.pickerCancelled()
            return true
        }

        // Enter/Return - confirm
        if keyCode == KeyCode.returnKey.rawValue || keyCode == KeyCode.keypadEnter.rawValue {
            delegate?.selectionConfirmed()
            return true
        }

        // Navigation keys
        if handleNavigation(keyCode: keyCode, modifiers: modifiers) {
            return true
        }

        // Text editing
        if handleTextEditing(keyCode: keyCode, modifiers: modifiers, event: event) {
            return true
        }

        // Regular character input
        if let chars = event.characters, !chars.isEmpty {
            let isControlKey = modifiers.contains(.control)
            let isCommandKey = modifiers.contains(.command)

            // Don't process if control/command held (except for known combos)
            if !isControlKey && !isCommandKey {
                insertText(chars)
                return true
            }
        }

        return false
    }

    /// Handle navigation keys
    private func handleNavigation(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let hasControl = modifiers.contains(.control)

        // Up arrow or Ctrl-P or Ctrl-K
        if keyCode == 126 || (hasControl && keyCode == 35) || (hasControl && keyCode == 40) {
            delegate?.selectionMoved(-1, count: 1)
            return true
        }

        // Down arrow or Ctrl-N or Ctrl-J
        if keyCode == 125 || (hasControl && keyCode == 45) || (hasControl && keyCode == 38) {
            delegate?.selectionMoved(1, count: 1)
            return true
        }

        // Page Up - move up by maxVisibleItems
        if keyCode == 116 {
            delegate?.selectionMoved(-1, count: maxVisibleItems)
            return true
        }

        // Page Down - move down by maxVisibleItems
        if keyCode == 121 {
            delegate?.selectionMoved(1, count: maxVisibleItems)
            return true
        }

        return false
    }

    /// Handle text editing keys
    private func handleTextEditing(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool {
        let hasControl = modifiers.contains(.control)
        let hasCommand = modifiers.contains(.command)

        // Backspace
        if keyCode == 51 {
            if hasCommand {
                // Cmd+Backspace - clear all
                query = ""
                cursorPosition = 0
            } else if cursorPosition > 0 {
                // Delete character before cursor
                let index = query.index(query.startIndex, offsetBy: cursorPosition - 1)
                query.remove(at: index)
                cursorPosition -= 1
            }
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Delete forward (Fn+Backspace)
        if keyCode == 117 {
            if cursorPosition < query.count {
                let index = query.index(query.startIndex, offsetBy: cursorPosition)
                query.remove(at: index)
            }
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Left arrow
        if keyCode == 123 {
            if hasCommand {
                cursorPosition = 0
            } else if cursorPosition > 0 {
                cursorPosition -= 1
            }
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Right arrow
        if keyCode == 124 {
            if hasCommand {
                cursorPosition = query.count
            } else if cursorPosition < query.count {
                cursorPosition += 1
            }
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Ctrl-A - beginning of line
        if hasControl && keyCode == 0 {
            cursorPosition = 0
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Ctrl-E - end of line
        if hasControl && keyCode == 14 {
            cursorPosition = query.count
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Ctrl-U - clear line
        if hasControl && keyCode == 32 {
            query = ""
            cursorPosition = 0
            delegate?.queryChanged(query, cursorPosition: cursorPosition)
            return true
        }

        // Ctrl-W - delete word backward
        if hasControl && keyCode == 13 {
            deleteWordBackward()
            return true
        }

        return false
    }

    /// Insert text at cursor position
    private func insertText(_ text: String) {
        let index = query.index(query.startIndex, offsetBy: cursorPosition)
        query.insert(contentsOf: text, at: index)
        cursorPosition += text.count
        delegate?.queryChanged(query, cursorPosition: cursorPosition)
    }

    /// Delete word backward (Ctrl-W style)
    private func deleteWordBackward() {
        guard cursorPosition > 0 else { return }

        var newPosition = cursorPosition - 1

        // Skip trailing whitespace
        while newPosition > 0 && query[query.index(query.startIndex, offsetBy: newPosition)].isWhitespace {
            newPosition -= 1
        }

        // Delete until start of word
        while newPosition > 0 && !query[query.index(query.startIndex, offsetBy: newPosition - 1)].isWhitespace {
            newPosition -= 1
        }

        let startIndex = query.index(query.startIndex, offsetBy: newPosition)
        let endIndex = query.index(query.startIndex, offsetBy: cursorPosition)
        query.removeSubrange(startIndex..<endIndex)
        cursorPosition = newPosition

        delegate?.queryChanged(query, cursorPosition: cursorPosition)
    }

    // MARK: - Mouse Handling

    private func handleMouseClick(_ event: NSEvent) {
        let location = event.locationInWindow

        // Convert to screen coordinates
        guard let window = event.window else {
            // If no window, use screen coordinates directly
            handleClickAtScreenLocation(NSEvent.mouseLocation)
            return
        }

        let screenLocation = window.convertPoint(toScreen: location)
        handleClickAtScreenLocation(screenLocation)
    }

    private func handleClickAtScreenLocation(_ location: NSPoint) {
        // Check if click is inside picker bounds
        // Note: Need to convert between AppKit (bottom-left) and our coordinate system
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgY = primaryHeight - location.y

        let clickPoint = CGPoint(x: location.x, y: cgY)

        // If click is outside picker, cancel
        if !pickerBounds.contains(clickPoint) {
            delegate?.pickerCancelled()
            return
        }

        // Calculate which item was clicked
        // List area starts at: bounds.y + padding, ends at: bounds.maxY - padding - inputHeight - padding
        let listTop = pickerBounds.maxY - padding - inputHeight - padding
        let listBottom = pickerBounds.minY + padding

        if cgY > listTop || cgY < listBottom {
            // Click in input area or outside list - ignore
            return
        }

        // Calculate item index (items render from top to bottom)
        let relativeY = listTop - cgY
        let itemIndex = Int(relativeY / itemHeight)

        if itemIndex >= 0 && itemIndex < maxVisibleItems {
            delegate?.itemClicked(at: itemIndex)
        }
    }

    // MARK: - Scroll Handling

    private func handleScroll(_ event: NSEvent) {
        let location = NSEvent.mouseLocation

        // Convert to CG coordinates
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgY = primaryHeight - location.y
        let clickPoint = CGPoint(x: location.x, y: cgY)

        // Only handle scroll if inside picker
        guard pickerBounds.contains(clickPoint) else { return }

        // Calculate scroll direction, accounting for natural scrolling preference
        var deltaY = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice {
            deltaY = -deltaY
        }
        if abs(deltaY) > 0.5 {
            let direction = deltaY > 0 ? -1 : 1
            delegate?.scrolled(by: direction)
        }
    }
}
