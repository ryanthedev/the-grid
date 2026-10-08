//
// MenuAutomation.swift
// GridServer
//
// An app's menu bar as an index of commands, read through accessibility
// without opening any menu, and a way to run one command by its path.
// Blocking AX: call everything here on `UIAutomation.shared.queue`.
//

import AppKit
import ApplicationServices
import Foundation

enum MenuError: Error, CustomStringConvertible {
    case noMenuBar(String)
    case unresponsive(String)
    case emptyPath
    case noSuchItem(wanted: String, under: String, siblings: [String])
    case isSubmenu(path: String, items: [String])
    case notSubmenu(String)
    case disabled(path: String, app: String)
    case notFrontmost(String)
    case pressFailed(path: String, AXError)

    var description: String {
        switch self {
        case .noMenuBar(let app): return "\(app) has no menu bar reachable through accessibility (a background agent, or an app that is still launching)"
        case .unresponsive(let app): return "\(app) did not answer (hung, or busy in a modal dialog); its menu bar could not be read"
        case .emptyPath: return "path is required, e.g. 'File > Export As > PDF…'"
        case .noSuchItem(let wanted, let under, let siblings):
            return "no menu item '\(wanted)' under \(under); it has: \(siblings.prefix(40).joined(separator: ", "))"
        case .isSubmenu(let path, let items):
            return "'\(path)' is a submenu, not a command; nothing was pressed. It has: \(items.prefix(40).joined(separator: ", "))"
        case .notSubmenu(let path): return "'\(path)' is a command, not a submenu; the path goes no further"
        case .disabled(let path, let app):
            return "menu item '\(path)' is disabled in \(app) right now, with the app frontmost, so that is its real state; nothing was pressed"
        case .notFrontmost(let app):
            return "\(app) did not come to the front, and the menu item is disabled while it is in the background; nothing was pressed"
        case .pressFailed(let path, let err): return "pressing menu item '\(path)' failed (AXError \(err.rawValue))"
        }
    }
}

extension MenuError {
    /// For the log: menu titles are user data (Open Recent lists file names), so the kind of failure only.
    var logSummary: String {
        switch self {
        case .noMenuBar: return "menu: no menu bar"
        case .unresponsive: return "menu: app unresponsive"
        case .emptyPath: return "menu: empty path"
        case .noSuchItem: return "menu: no such item"
        case .isSubmenu: return "menu: path is a submenu"
        case .notSubmenu: return "menu: path continues past a command"
        case .disabled: return "menu: item disabled"
        case .notFrontmost: return "menu: app did not come forward"
        case .pressFailed(_, let err): return "menu: AXPress failed (AXError \(err.rawValue))"
        }
    }
}

/// One command of a menu bar.
struct MenuEntry {
    let path: [String]
    let shortcut: String?
    let enabled: Bool
    var checked = false

    /// `File > Export As > PDF…  [cmd+shift+P]  enabled`
    var line: String {
        var parts = [path.joined(separator: " > ")]
        if let shortcut { parts.append("[\(shortcut)]") }
        parts.append(enabled ? "enabled" : "disabled")
        if checked { parts.append("checked") }
        return parts.joined(separator: "  ")
    }

    func matches(text: String?, enabled wanted: Bool?) -> Bool {
        if let wanted, wanted != enabled { return false }
        guard let text else { return true }
        let needle = MenuPath.normalize(text)
        return MenuPath.normalize(path.joined(separator: " > ")).contains(needle) || (shortcut?.lowercased().contains(needle) ?? false)
    }
}

/// `File > Export As > PDF…` as the caller writes it, against titles as the app reports them.
enum MenuPath {
    static func parse(_ path: String) -> [String] {
        path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Case, runs of whitespace and the two spellings of an ellipsis do not tell items apart.
    static func normalize(_ title: String) -> String {
        (UINode.clean(title) ?? "").lowercased().replacingOccurrences(of: "…", with: "...")
    }

    /// Indexes of the titles a path segment names: exact matches, else matches that differ only
    /// by a trailing ellipsis ("Save As" finds "Save As…").
    static func matches(_ wanted: String, among titles: [String]) -> [Int] {
        let want = normalize(wanted)
        let exact = titles.indices.filter { normalize(titles[$0]) == want }
        if !exact.isEmpty { return exact }
        let bare = { (s: String) in normalize(s).replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces) }
        return titles.indices.filter { bare(titles[$0]) == bare(wanted) }
    }
}

enum MenuAutomation {
    struct Limits {
        var limit = 1000
        var maxScanned = 5000
        var maxDepth = 8
        var deadline: TimeInterval = 3
    }

    // MARK: - Shortcuts

    /// AXMenuItemCmdModifiers: bit 0 shift, 1 option, 2 control, 3 "no command", 4 fn.
    /// The key is AXMenuItemCmdChar, else a virtual keycode, else a Carbon menu glyph.
    /// Written the way input.key.press reads it: `cmd+shift+P`, `cmd+backspace`.
    static func shortcut(char: String?, modifiers: Int?, virtualKey: Int?, glyph: Int?) -> String? {
        var key: String?
        if let char, let scalar = char.unicodeScalars.first {
            key = charNames[scalar.value] ?? (scalar.properties.generalCategory == .control ? nil : char)
        }
        if key == nil, let virtualKey { key = keyNames[virtualKey] }
        if key == nil, let glyph { key = glyphNames[glyph] }
        guard let key else { return nil }
        let mods = modifiers ?? 0
        var parts: [String] = []
        if mods & 8 == 0 { parts.append("cmd") }
        if mods & 4 != 0 { parts.append("ctrl") }
        if mods & 2 != 0 { parts.append("alt") }
        if mods & 1 != 0 { parts.append("shift") }
        if mods & 16 != 0 { parts.append("fn") }
        return (parts + [key]).joined(separator: "+")
    }

    private static let charNames: [UInt32: String] = [
        0x03: "enter", 0x0D: "enter", 0x09: "tab", 0x20: "space", 0x1B: "escape", 0x08: "backspace", 0x7F: "backspace",
        0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right", 0xF728: "forwarddelete",
    ]

    // Keycode -> the name input.key.press takes. Where BFD has two names for a key, the first listed here wins.
    private static let keyNames: [Int: String] = {
        var out: [Int: String] = [:]
        let preferred = ["enter", "backspace", "escape", "tab", "space", "forwarddelete", "left", "right", "up", "down"]
        for name in preferred + BFDKeycodes.keys.sorted() {
            guard let code = BFDKeycodes[name], out[Int(code)] == nil else { continue }
            out[Int(code)] = name
        }
        return out
    }()

    // Carbon menu glyphs (Menus.h) for keys that have no character.
    private static let glyphNames: [Int: String] = {
        var out: [Int: String] = [
            0x02: "tab", 0x03: "tab", 0x04: "enter", 0x09: "space", 0x0A: "forwarddelete", 0x0B: "enter", 0x0D: "enter",
            0x17: "backspace", 0x1B: "escape", 0x64: "left", 0x65: "right", 0x68: "up", 0x6A: "down",
            0x62: "pageup", 0x6B: "pagedown", 0x66: "home", 0x69: "end",
        ]
        for n in 1...12 { out[0x6E + n] = "f\(n)" }
        return out
    }()

    // MARK: - Reading

    private struct Item {
        let element: AXUIElement
        var title = ""
        var enabled = true
        var children: [AXUIElement] = []
        var shortcut: String?
        var checked = false
        var unresponsive = false
    }

    private static let attributeNames: [String] = [
        kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
        kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemMarkCharAttribute,
    ]

    // One IPC round trip per item.
    private static func read(_ element: AXUIElement) -> Item {
        var item = Item(element: element)
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, attributeNames as CFArray, [], &valuesRef)
        item.unresponsive = err == .cannotComplete
        guard err == .success, let values = valuesRef as? [Any], values.count == attributeNames.count else { return item }
        item.title = UINode.clean(values[0] as? String) ?? ""
        item.enabled = values[1] as? Bool ?? true
        item.children = values[2] as? [AXUIElement] ?? []
        item.shortcut = shortcut(char: values[3] as? String, modifiers: (values[4] as? NSNumber)?.intValue,
                                 virtualKey: (values[5] as? NSNumber)?.intValue, glyph: (values[6] as? NSNumber)?.intValue)
        item.checked = !((values[7] as? String) ?? "").isEmpty
        return item
    }

    /// The items of the submenu an item opens: its one AXMenu child's children. nil when the app stopped answering.
    private static func submenu(of item: Item) -> [AXUIElement]? {
        var out: [AXUIElement] = []
        for child in item.children {
            var ref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &ref)
            if err == .cannotComplete { return nil }
            out += ref as? [AXUIElement] ?? []
        }
        return out
    }

    /// The top-level menus, without the Apple menu (always first; Shut Down and Log Out live there).
    private static func topLevel(pid: pid_t, app: String) throws -> [AXUIElement] {
        var barRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(makeAppElement(pid: pid), kAXMenuBarAttribute as CFString, &barRef)
        if err == .cannotComplete { throw MenuError.unresponsive(app) }
        guard err == .success, let bar = barRef, CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw MenuError.noMenuBar(app) }
        var children: CFTypeRef?
        let childErr = AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        if childErr == .cannotComplete { throw MenuError.unresponsive(app) }
        return Array((children as? [AXUIElement] ?? []).dropFirst())
    }

    /// Every command of the app's menu bar, one line each. Opens nothing and does not activate the app.
    static func snapshot(pid: pid_t, app: String, text: String?, enabled: Bool?, limits: Limits = Limits()) throws -> [String: Any] {
        var entries: [MenuEntry] = []
        var scanned = 0
        var truncated: String?
        let stopAt = Date().addingTimeInterval(limits.deadline)

        func walk(_ element: AXUIElement, path: [String], depth: Int) {
            guard truncated == nil else { return }
            if Date() > stopAt { truncated = "deadline"; return }
            if scanned >= limits.maxScanned { truncated = "maxScanned"; return }
            let item = read(element)
            if item.unresponsive { truncated = "unresponsive"; return }
            // Separators have no title.
            guard !item.title.isEmpty else { return }
            let here = path + [item.title]
            guard let below = submenu(of: item) else { truncated = "unresponsive"; return }
            if below.isEmpty || depth >= limits.maxDepth {
                scanned += 1
                var entry = MenuEntry(path: here, shortcut: item.shortcut, enabled: item.enabled)
                entry.checked = item.checked
                guard entry.matches(text: text, enabled: enabled) else { return }
                if entries.count >= limits.limit { truncated = "limit"; return }
                entries.append(entry)
                return
            }
            for child in below { walk(child, path: here, depth: depth + 1) }
        }
        for menu in try topLevel(pid: pid, app: app) { walk(menu, path: [], depth: 0) }

        var result: [String: Any] = ["app": app, "pid": Int(pid), "count": entries.count, "scanned": scanned,
                                     "outline": entries.map(\.line).joined(separator: "\n")]
        if let truncated { result["truncated"] = truncated }
        return result
    }

    // MARK: - Invoking

    /// Walk down `path` one level at a time and press the command it names.
    ///
    /// An app in the background has no key window, so it reports its document commands
    /// (Select All, Save) disabled, and AXPress on a disabled item answers success and does
    /// nothing. So the app is brought to the front first, and a disabled item is refused only
    /// after that. `activate` is false when the caller has already focused one of its windows.
    static func invoke(pid: pid_t, app: String, path: String, activate: Bool) throws -> [String: Any] {
        let segments = MenuPath.parse(path)
        guard !segments.isEmpty else { throw MenuError.emptyPath }

        var level = try topLevel(pid: pid, app: app)
        var walked: [String] = []
        var leaf: Item?
        for (i, segment) in segments.enumerated() {
            let items = level.map(read)
            if items.contains(where: { $0.unresponsive }) { throw MenuError.unresponsive(app) }
            let named = items.filter { !$0.title.isEmpty }
            let hits = MenuPath.matches(segment, among: named.map(\.title)).map { named[$0] }
            guard !hits.isEmpty else {
                let under = walked.isEmpty ? "the menu bar" : "'\(walked.joined(separator: " > "))'"
                throw MenuError.noSuchItem(wanted: segment, under: under, siblings: named.map(\.title))
            }
            if i == segments.count - 1 {
                // Alternates share a title (Finder has three "Eject"): take the enabled one.
                let choice = hits.first { $0.enabled } ?? hits[0]
                walked.append(choice.title)
                guard let below = submenu(of: choice) else { throw MenuError.unresponsive(app) }
                guard below.isEmpty else {
                    throw MenuError.isSubmenu(path: walked.joined(separator: " > "), items: below.map(read).map(\.title).filter { !$0.isEmpty })
                }
                leaf = choice
            } else {
                // On the way down, take the match that leads somewhere.
                var next: [AXUIElement] = []
                for hit in hits where next.isEmpty {
                    guard let below = submenu(of: hit) else { throw MenuError.unresponsive(app) }
                    next = below
                }
                walked.append(hits[0].title)
                guard !next.isEmpty else { throw MenuError.notSubmenu(walked.joined(separator: " > ")) }
                level = next
            }
        }
        guard let leaf else { throw MenuError.emptyPath }
        let resolved = walked.joined(separator: " > ")

        var activated = false
        if activate, !isFrontmost(pid) {
            AXUIElementSetAttributeValue(makeAppElement(pid: pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            activated = true
            let giveUp = Date().addingTimeInterval(1.0)
            while !isFrontmost(pid), Date() < giveUp { Thread.sleep(forTimeInterval: 0.025) }
        }
        // The menu re-validates a moment after the app comes forward.
        let giveUp = Date().addingTimeInterval(1.0)
        while !isEnabled(leaf.element), Date() < giveUp { Thread.sleep(forTimeInterval: 0.05) }
        guard isEnabled(leaf.element) else {
            throw isFrontmost(pid) ? MenuError.disabled(path: resolved, app: app) : MenuError.notFrontmost(app)
        }

        var result: [String: Any] = ["invoked": resolved, "app": app, "pid": Int(pid), "activated": activated]
        if let shortcut = leaf.shortcut { result["shortcut"] = shortcut }
        let err = AXUIElementPerformAction(leaf.element, kAXPressAction as CFString)
        switch err {
        case .success:
            result["via"] = "AXPress"
        case .cannotComplete:
            // A command that opens a modal dialog keeps the app from answering until it closes.
            result["via"] = "AXPress (no reply)"
            result["note"] = "The app did not answer the press, which is what a command that opens a modal dialog looks like. Look before retrying."
        default:
            throw MenuError.pressFailed(path: resolved, err)
        }
        return result
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: - Finding the app

    /// A running app by name ("TextEdit", any case) or bundle identifier. Some names carry
    /// invisible marks (WhatsApp's starts with U+200E), which no caller will type.
    static func runningApp(named name: String) -> NSRunningApplication? {
        let want = plain(name)
        let apps = NSWorkspace.shared.runningApplications.filter {
            plain($0.localizedName ?? "") == want || ($0.bundleIdentifier ?? "").lowercased() == want
        }
        return apps.first { $0.activationPolicy == .regular } ?? apps.first
    }

    static func plain(_ name: String) -> String {
        (plainName(name) ?? "").lowercased()
    }

    /// The name without invisible formatting marks; nil when nothing is left.
    static func plainName(_ name: String?) -> String? {
        guard let name else { return nil }
        let visible = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespaces)
        return visible.isEmpty ? nil : visible
    }
}
