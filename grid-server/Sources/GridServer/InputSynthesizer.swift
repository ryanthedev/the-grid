//
// InputSynthesizer.swift
// GridServer
//
// Synthesizes mouse and keyboard input via CGEvent. Lives in the server
// because this process already holds the Accessibility grant; a CLI posting
// events would be attributed to whatever launched it.
//
// Every entry point sleeps between events so apps see human-shaped input,
// so callers must run these off the cooperative pool (see `queue`).
//

import Foundation
import CoreGraphics
import Carbon.HIToolbox

enum InputError: Error, CustomStringConvertible {
    case offScreen(CGPoint)
    case badKeyCombo(String)
    case eventFailed(String)

    var description: String {
        switch self {
        case .offScreen(let p): return "Point (\(Int(p.x)), \(Int(p.y))) is outside every display"
        case .badKeyCombo(let s): return "Unknown key combo '\(s)'"
        case .eventFailed(let s): return "Could not create \(s) event"
        }
    }
}

enum MouseButton: String {
    case left, right, middle

    var down: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var up: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var dragged: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}

/// A parsed key chord: modifier flags plus a virtual keycode.
struct KeyCombo: Equatable {
    let flags: CGEventFlags
    let keyCode: UInt32
}

/// Parse "cmd+shift+s", "cmd+shift-s", "ctrl-h", or a bare "enter".
///
/// BFD's parser splits on the last "-" only; agents overwhelmingly write
/// "cmd+s", so accept "+" as the separator too. A trailing "+" or "-" is the
/// key itself ("cmd++" is cmd and plus, "cmd+-" is cmd and minus).
func parseKeyCombo(_ spec: String) throws -> KeyCombo {
    let trimmed = spec.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw InputError.badKeyCombo(spec) }

    var parts: [String]
    if trimmed.count == 1 {
        parts = [trimmed]
    } else if trimmed.hasSuffix("+") || trimmed.hasSuffix("-") {
        let key = String(trimmed.last!)
        let head = String(trimmed.dropLast())
        // The separator before the key can be either character.
        let mods = head.dropLast()
        parts = mods.split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init) + [key]
    } else {
        parts = trimmed.split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init)
    }
    guard let keyPart = parts.popLast()?.lowercased() else { throw InputError.badKeyCombo(spec) }
    guard let keyCode = BFDKeycodes[keyPart] else { throw InputError.badKeyCombo(spec) }

    var flags = CGEventFlags()
    for mod in parts.map({ $0.lowercased() }) {
        switch mod {
        case "cmd", "command", "lcmd", "rcmd", "super", "meta": flags.insert(.maskCommand)
        case "alt", "opt", "option", "lalt", "ralt": flags.insert(.maskAlternate)
        case "ctrl", "control", "lctrl", "rctrl": flags.insert(.maskControl)
        case "shift", "lshift", "rshift": flags.insert(.maskShift)
        case "fn": flags.insert(.maskSecondaryFn)
        case "hyper": flags.formUnion([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        case "meh": flags.formUnion([.maskAlternate, .maskControl, .maskShift])
        default: throw InputError.badKeyCombo(spec)
        }
    }
    return KeyCombo(flags: flags, keyCode: keyCode)
}

/// Parse a modifier list ("cmd+shift") into flags for mouse events.
func parseModifierFlags(_ spec: String?) throws -> CGEventFlags {
    guard let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    // Reuse the combo parser with a throwaway key.
    return try parseKeyCombo("\(spec)+a").flags
}

final class InputSynthesizer {
    static let shared = InputSynthesizer()

    /// Serial queue for synthesis. Handlers run on the cooperative pool and
    /// must not sleep there; hop here and complete from here.
    let queue = DispatchQueue(label: "com.thegrid.input", qos: .userInteractive)

    private let source = CGEventSource(stateID: .hidSystemState)

    // Delays in seconds. Apps drop events that arrive with no gap.
    private let settle: TimeInterval = 0.02
    private let dragStepDelay: TimeInterval = 0.01

    /// Screen frames used for the bounds check; refreshed by callers with
    /// the state manager's display list before each request.
    var displayFrames: [CGRect] = []

    // MARK: - Query

    func position() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: - Mouse

    func move(to point: CGPoint) throws {
        try checkOnScreen(point)
        try post(.mouseMoved, at: point, button: .left)
        sleep(settle)
    }

    func click(at point: CGPoint?, button: MouseButton = .left, count: Int = 1, flags: CGEventFlags = []) throws -> CGPoint {
        let target = point ?? position()
        try move(to: target)
        for n in 1...max(count, 1) {
            try post(button.down, at: target, button: button, clickState: n, flags: flags)
            sleep(settle)
            try post(button.up, at: target, button: button, clickState: n, flags: flags)
            if n < count { sleep(settle * 2) }
        }
        return target
    }

    func drag(from: CGPoint, to: CGPoint, button: MouseButton = .left, steps: Int = 12, flags: CGEventFlags = []) throws {
        try checkOnScreen(from)
        try checkOnScreen(to)
        try move(to: from)
        try post(button.down, at: from, button: button, clickState: 1, flags: flags)
        sleep(settle * 3)
        let n = max(steps, 1)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            try post(button.dragged, at: p, button: button, clickState: 1, flags: flags)
            sleep(dragStepDelay)
        }
        sleep(settle * 3)
        try post(button.up, at: to, button: button, clickState: 1, flags: flags)
        sleep(settle)
    }

    /// Positive dy scrolls content up (wheel toward the user is negative),
    /// matching the sign CGEvent uses.
    func scroll(at point: CGPoint?, dx: Int, dy: Int, flags: CGEventFlags = []) throws -> CGPoint {
        let target = point ?? position()
        try move(to: target)
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw InputError.eventFailed("scroll")
        }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
        sleep(settle)
        return target
    }

    // MARK: - Keyboard

    /// Type literal text. Modifier flags are cleared so text never becomes a
    /// shortcut; use `press` for chords.
    func type(_ text: String) throws {
        let units = Array(text.utf16)
        // keyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for type in [CGEventType.keyDown, .keyUp] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: type == .keyDown) else {
                    throw InputError.eventFailed("key")
                }
                ev.flags = []
                chunk.withUnsafeBufferPointer { buf in
                    ev.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                ev.post(tap: .cghidEventTap)
            }
            sleep(settle)
            i += 20
        }
    }

    func press(_ combo: KeyCombo, count: Int = 1) throws {
        for _ in 0..<max(count, 1) {
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: down) else {
                    throw InputError.eventFailed("key")
                }
                ev.flags = combo.flags
                ev.post(tap: .cghidEventTap)
                sleep(settle)
            }
        }
    }

    // MARK: - Helpers

    private func checkOnScreen(_ p: CGPoint) throws {
        // No display info yet (early startup): let it through.
        guard !displayFrames.isEmpty else { return }
        guard displayFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) else {
            throw InputError.offScreen(p)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: MouseButton,
                      clickState: Int = 0, flags: CGEventFlags = []) throws {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cgButton) else {
            throw InputError.eventFailed("mouse")
        }
        if clickState > 0 {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        if button == .middle {
            ev.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }

    private func sleep(_ s: TimeInterval) {
        Thread.sleep(forTimeInterval: s)
    }
}
