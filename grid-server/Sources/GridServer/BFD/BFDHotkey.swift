import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Modifier flags for hotkey matching
struct BFDModifiers: OptionSet, Hashable {
    let rawValue: UInt32

    static let cmd     = BFDModifiers(rawValue: 1 << 0)
    static let lCmd    = BFDModifiers(rawValue: 1 << 1)
    static let rCmd    = BFDModifiers(rawValue: 1 << 2)
    static let alt     = BFDModifiers(rawValue: 1 << 3)
    static let lAlt    = BFDModifiers(rawValue: 1 << 4)
    static let rAlt    = BFDModifiers(rawValue: 1 << 5)
    static let ctrl    = BFDModifiers(rawValue: 1 << 6)
    static let lCtrl   = BFDModifiers(rawValue: 1 << 7)
    static let rCtrl   = BFDModifiers(rawValue: 1 << 8)
    static let shift   = BFDModifiers(rawValue: 1 << 9)
    static let lShift  = BFDModifiers(rawValue: 1 << 10)
    static let rShift  = BFDModifiers(rawValue: 1 << 11)
    static let fn      = BFDModifiers(rawValue: 1 << 12)

    static let hyper: BFDModifiers = [.cmd, .alt, .ctrl, .shift]
    static let meh: BFDModifiers = [.alt, .ctrl, .shift]
}

/// Parsed hotkey for lookup
struct BFDHotkeyKey: Hashable {
    let modifiers: BFDModifiers
    let keyCode: UInt32
}

/// Keycode mappings (subset - add more as needed)
let BFDKeycodes: [String: UInt32] = [
    // Letters
    "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
    "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
    "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
    "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
    "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
    "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
    "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
    "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
    "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),

    // Numbers
    "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
    "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
    "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
    "9": UInt32(kVK_ANSI_9),

    // Special keys
    "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
    "tab": UInt32(kVK_Tab), "space": UInt32(kVK_Space),
    "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
    "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
    "forwarddelete": UInt32(kVK_ForwardDelete),

    // Arrow keys
    "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
    "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),

    // Function keys
    "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3),
    "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6),
    "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8), "f9": UInt32(kVK_F9),
    "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),

    // Symbols
    "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
    "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
    ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
    "\\": UInt32(kVK_ANSI_Backslash), ",": UInt32(kVK_ANSI_Comma),
    ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),
    "`": UInt32(kVK_ANSI_Grave), "backtick": UInt32(kVK_ANSI_Grave),
]

/// Parse a hotkey spec like "cmd+shift-h" into (modifiers, keyCode)
func parseBFDHotkey(_ spec: String) throws -> BFDHotkeyKey {
    // Split on last "-" to separate modifiers from key
    guard let dashIndex = spec.lastIndex(of: "-") else {
        throw BFDParseError.invalidFormat(spec)
    }

    let modPart = String(spec[..<dashIndex])
    let keyPart = String(spec[spec.index(after: dashIndex)...]).lowercased()

    // Parse modifiers (split on "+")
    var modifiers = BFDModifiers()
    let modNames = modPart.split(separator: "+").map { String($0).lowercased() }

    for mod in modNames {
        switch mod {
        case "cmd", "command": modifiers.insert(.cmd)
        case "lcmd": modifiers.insert(.lCmd)
        case "rcmd": modifiers.insert(.rCmd)
        case "alt", "opt", "option": modifiers.insert(.alt)
        case "lalt": modifiers.insert(.lAlt)
        case "ralt": modifiers.insert(.rAlt)
        case "ctrl", "control": modifiers.insert(.ctrl)
        case "lctrl": modifiers.insert(.lCtrl)
        case "rctrl": modifiers.insert(.rCtrl)
        case "shift": modifiers.insert(.shift)
        case "lshift": modifiers.insert(.lShift)
        case "rshift": modifiers.insert(.rShift)
        case "fn": modifiers.insert(.fn)
        case "hyper": modifiers.formUnion(.hyper)
        case "meh": modifiers.formUnion(.meh)
        default:
            throw BFDParseError.unknownModifier(mod)
        }
    }

    // Parse key
    guard let keyCode = BFDKeycodes[keyPart] else {
        throw BFDParseError.unknownKey(keyPart)
    }

    return BFDHotkeyKey(modifiers: modifiers, keyCode: keyCode)
}

/// Convert CGEvent flags to BFDModifiers
func bfdModifiersFromCGEvent(_ flags: CGEventFlags) -> BFDModifiers {
    var result = BFDModifiers()

    if flags.contains(.maskCommand) {
        // Check for left/right specific (using raw flag bits)
        let raw = flags.rawValue
        let leftCmd = (raw & UInt64(NX_DEVICELCMDKEYMASK)) != 0
        let rightCmd = (raw & UInt64(NX_DEVICERCMDKEYMASK)) != 0
        if leftCmd { result.insert(.lCmd) }
        if rightCmd { result.insert(.rCmd) }
        result.insert(.cmd)
    }

    if flags.contains(.maskAlternate) {
        let raw = flags.rawValue
        let leftAlt = (raw & UInt64(NX_DEVICELALTKEYMASK)) != 0
        let rightAlt = (raw & UInt64(NX_DEVICERALTKEYMASK)) != 0
        if leftAlt { result.insert(.lAlt) }
        if rightAlt { result.insert(.rAlt) }
        result.insert(.alt)
    }

    if flags.contains(.maskControl) {
        let raw = flags.rawValue
        let leftCtrl = (raw & UInt64(NX_DEVICELCTLKEYMASK)) != 0
        let rightCtrl = (raw & UInt64(NX_DEVICERCTLKEYMASK)) != 0
        if leftCtrl { result.insert(.lCtrl) }
        if rightCtrl { result.insert(.rCtrl) }
        result.insert(.ctrl)
    }

    if flags.contains(.maskShift) {
        let raw = flags.rawValue
        let leftShift = (raw & UInt64(NX_DEVICELSHIFTKEYMASK)) != 0
        let rightShift = (raw & UInt64(NX_DEVICERSHIFTKEYMASK)) != 0
        if leftShift { result.insert(.lShift) }
        if rightShift { result.insert(.rShift) }
        result.insert(.shift)
    }

    if flags.contains(.maskSecondaryFn) {
        result.insert(.fn)
    }

    return result
}

/// Check if event modifiers match hotkey modifiers
/// Config can specify general "cmd" which matches any cmd, or specific "lcmd"
func bfdModifiersMatch(config: BFDModifiers, event: BFDModifiers) -> Bool {
    // For each modifier type, check if config requires it

    // Command
    if config.contains(.lCmd) && !event.contains(.lCmd) { return false }
    if config.contains(.rCmd) && !event.contains(.rCmd) { return false }
    if config.contains(.cmd) && !config.contains(.lCmd) && !config.contains(.rCmd) {
        if !event.contains(.cmd) { return false }
    }

    // Alt
    if config.contains(.lAlt) && !event.contains(.lAlt) { return false }
    if config.contains(.rAlt) && !event.contains(.rAlt) { return false }
    if config.contains(.alt) && !config.contains(.lAlt) && !config.contains(.rAlt) {
        if !event.contains(.alt) { return false }
    }

    // Control
    if config.contains(.lCtrl) && !event.contains(.lCtrl) { return false }
    if config.contains(.rCtrl) && !event.contains(.rCtrl) { return false }
    if config.contains(.ctrl) && !config.contains(.lCtrl) && !config.contains(.rCtrl) {
        if !event.contains(.ctrl) { return false }
    }

    // Shift
    if config.contains(.lShift) && !event.contains(.lShift) { return false }
    if config.contains(.rShift) && !event.contains(.rShift) { return false }
    if config.contains(.shift) && !config.contains(.lShift) && !config.contains(.rShift) {
        if !event.contains(.shift) { return false }
    }

    // Fn
    if config.contains(.fn) && !event.contains(.fn) { return false }

    // Check that event doesn't have extra modifiers not in config
    // (e.g., config is "cmd-h" but user pressed "cmd+shift-h")
    if !config.contains(.cmd) && !config.contains(.lCmd) && !config.contains(.rCmd) {
        if event.contains(.cmd) { return false }
    }
    if !config.contains(.alt) && !config.contains(.lAlt) && !config.contains(.rAlt) {
        if event.contains(.alt) { return false }
    }
    if !config.contains(.ctrl) && !config.contains(.lCtrl) && !config.contains(.rCtrl) {
        if event.contains(.ctrl) { return false }
    }
    if !config.contains(.shift) && !config.contains(.lShift) && !config.contains(.rShift) {
        if event.contains(.shift) { return false }
    }

    return true
}

enum BFDParseError: Error {
    case invalidFormat(String)
    case unknownModifier(String)
    case unknownKey(String)
}
