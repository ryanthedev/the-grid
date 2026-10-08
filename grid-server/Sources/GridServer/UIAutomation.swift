//
// UIAutomation.swift
// GridServer
//
// Accessibility snapshots of a window's UI for the ui.* RPC methods: a compact
// text outline where every node carries a ref, plus actions on those refs.
// Frames are global Quartz points (top-left origin), the space input.* uses.
//

import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

enum UIError: Error, CustomStringConvertible {
    case unknownRef(String)
    case axFailed(String, AXError)
    case noFrame(String)
    case unreachable(UInt32)
    case covered(String)
    case secureField

    var description: String {
        switch self {
        case .unknownRef(let ref): return "unknown ref '\(ref)' -- a full ui.snapshot of a window (or observe=snapshot, or another client's snapshot) retires that window's earlier refs; take the ref from the latest outline"
        case .axFailed(let op, let err): return "\(op) failed (AXError \(err.rawValue))"
        case .noFrame(let ref): return "ref '\(ref)' has no frame to click"
        case .covered(let why): return why
        case .secureField: return "that is a password field; writing to it is refused unless the call passes allowSecure=true"
        case .unreachable(let wid): return "window \(wid) is not reachable through accessibility -- its app did not answer or does not list it (hung, minimized, or on a space that is not visible)"
        }
    }
}

/// One emitted node of a snapshot.
struct UINode {
    let ref: String
    var depth: Int
    let role: String
    var subrole: String? = nil
    let title: String?
    let value: String?
    let description: String?
    let frame: CGRect?
    let enabled: Bool
    let focused: Bool
    // Whether the element really lists AXPress. A role is only a hint:
    // Finder's disclosure triangles look pressable and are not.
    var pressable: Bool? = nil
    var offscreen = false
    var selected = false
    // Borrowed from the text beside an unlabelled control: `for="Use scroll gesture…"`.
    var label: String? = nil

    // Roles worth asking for their actions (one more IPC each); everything
    // else is assumed not pressable.
    static let pressCandidates: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
        "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXTab",
    ]

    /// `  [14442:7] AXButton "Send" (1204,-220 64x28) press`
    var line: String {
        var parts = [String(repeating: "  ", count: depth) + "[\(ref)]"]
        // An unlabelled control is only identifiable by its subrole (AXCloseButton).
        if let subrole, title == nil, description == nil {
            parts.append("\(role):\(subrole)")
        } else {
            parts.append(role)
        }
        if let title { parts.append("\"\(title)\"") }
        if let value { parts.append("value=\"\(value)\"") }
        if let description, description != title { parts.append("desc=\"\(description)\"") }
        if let label { parts.append("for=\"\(label)\"") }
        // Frames come from the app; Int() would trap on a huge or non-finite one.
        if let f = frame, let x = Int(exactly: f.minX.rounded()), let y = Int(exactly: f.minY.rounded()),
           let w = Int(exactly: f.width.rounded()), let h = Int(exactly: f.height.rounded()) {
            parts.append("(\(x),\(y) \(w)x\(h))")
        }
        if pressable ?? Self.pressCandidates.contains(role) { parts.append("press") }
        if selected { parts.append("selected") }
        if offscreen { parts.append("offscreen") }
        if focused { parts.append("focused") }
        if !enabled { parts.append("disabled") }
        return parts.joined(separator: " ")
    }

    /// Containers with nothing to say are walked through but not printed.
    static func isWorthEmitting(role: String, title: String?, value: String?, description: String?) -> Bool {
        if title != nil || value != nil || description != nil { return true }
        // A picture with no label says nothing in text.
        if role == "AXImage" { return false }
        return !["AXGroup", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXGenericElement", "AXRow", "AXCell", "AXColumn"].contains(role)
    }

    /// Collapse whitespace and cap the length so one node stays one line.
    static func clean(_ s: String?, limit: Int = 120) -> String? {
        guard let s else { return nil }
        let flat = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        let capped = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return capped.replacingOccurrences(of: "\"", with: "'")
    }
}

/// "Find me the Save button": a predicate applied inside the walk, so the
/// answer is three lines instead of four hundred.
struct UIQuery {
    var role: String?
    var text: String?
    var pressable: Bool?
    var limit = 20

    func matches(_ node: UINode) -> Bool {
        if let role, !Self.sameRole(role, node.role), !Self.sameRole(role, node.subrole ?? "") { return false }
        if let pressable, (node.pressable ?? UINode.pressCandidates.contains(node.role)) != pressable { return false }
        if let text {
            let haystack = [node.title, node.value, node.description, node.label].compactMap { $0 }
            guard haystack.contains(where: { $0.localizedCaseInsensitiveContains(text) }) else { return false }
        }
        return true
    }

    /// "button", "Button" and "AXButton" all mean AXButton.
    static func sameRole(_ wanted: String, _ actual: String) -> Bool {
        let strip = { (s: String) in (s.hasPrefix("AX") ? String(s.dropFirst(2)) : s).lowercased() }
        return !actual.isEmpty && strip(wanted) == strip(actual)
    }
}

final class UIAutomation {
    static let shared = UIAutomation()

    /// Serial queue for every AX walk and for the ref table. AX IPC blocks,
    /// so it must stay off the cooperative pool.
    let queue = DispatchQueue(label: "com.thegrid.ui", qos: .userInitiated)

    // Refs per window; a full snapshot replaces that window's table.
    private var refs: [UInt32: [String: AXUIElement]] = [:]
    private var refOrder: [UInt32] = []
    // Last ref number handed out per window. It only ever grows, so a ref from before a
    // re-snapshot can never come to mean a different element: it is simply unknown.
    private var lastRefNumber: [UInt32: Int] = [:]

    private static func number(of ref: String) -> Int {
        Int(ref.split(separator: ":").last ?? "") ?? 0
    }

    /// AXUIElement identity for dictionary lookups (CFEqual / CFHash).
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    // The window element of each tracked window, for its live frame.
    private var roots: [UInt32: AXUIElement] = [:]
    private let maxTrackedWindows = 8

    struct Limits {
        var maxDepth = 30
        var maxNodes = 400
        var deadline: TimeInterval = 3
        // List content scrolled out of view too, flagged `offscreen`, so it can be ui.scrollTo'd.
        var includeOffscreen = false
        // Return only the nodes that match, instead of the whole outline.
        var query: UIQuery?
    }

    // MARK: - Snapshot

    /// Walk `root` (a window, or a ref's element for a subtree). Call on `queue`.
    func snapshot(windowID: UInt32, root: AXUIElement, subtree: Bool, limits: Limits) -> [String: Any] {
        // An element that was in the previous outline keeps its ref, so looking again does not
        // invalidate what the caller already holds; elements that are gone lose theirs, and
        // numbers are never handed to a different element.
        var known: [ElementKey: String] = [:]
        // Oldest ref wins when an element somehow holds two.
        for (ref, element) in (refs[windowID] ?? [:]).sorted(by: { Self.number(of: $0.key) > Self.number(of: $1.key) }) {
            known[ElementKey(element: element)] = ref
        }
        if !subtree {
            refs[windowID] = [:]
            roots[windowID] = root
        }
        touch(windowID)
        // Clip to the window's frame as AX reports it now; the state cache can
        // lag a move and would prune the whole tree.
        let windowFrame = roots[windowID].flatMap { Self.copyAttributes($0).frame }
        var table = refs[windowID] ?? [:]
        var next = (lastRefNumber[windowID] ?? 0) + 1
        var lines: [UINode?] = []
        var truncated: String?
        let stopAt = Date().addingTimeInterval(limits.deadline)

        // While inside a table row, its cells' texts are gathered here and
        // printed as one line: `AXRow "name | date | size | kind"`.
        var rowTexts: [String]?
        // Static texts seen so far among the current siblings, for label inference.
        var siblingTexts: [[(text: String, frame: CGRect?)]] = [[]]

        func takeRef(_ element: AXUIElement) -> String {
            // The same element listed twice (a menu under two parents) is the same ref twice.
            if let kept = known[ElementKey(element: element)] { return kept }
            defer { next += 1 }
            return "\(windowID):\(next)"
        }

        func walkChildren(_ children: [AXUIElement], depth: Int, printDepth: Int) {
            siblingTexts.append([])
            for child in children { walk(child, depth: depth + 1, printDepth: printDepth) }
            siblingTexts.removeLast()
        }

        func walk(_ element: AXUIElement, depth: Int, printDepth: Int) {
            guard truncated == nil else { return }
            if lines.count >= limits.maxNodes { truncated = "maxNodes"; return }
            if Date() > stopAt { truncated = "deadline"; return }

            let attrs = Self.copyAttributes(element)
            // The app stopped answering: every further node would cost a full
            // messaging timeout, so stop now instead of at the deadline.
            if attrs.unresponsive { truncated = "unresponsive"; return }
            let frame = attrs.frame
            // Scrolled-out content: a real frame that misses the window entirely.
            var offscreen = false
            if depth > 0, let frame, let windowFrame, frame.width > 0, frame.height > 0, !frame.intersects(windowFrame) {
                guard limits.includeOffscreen else { return }
                offscreen = true
            }
            // A scroll bar's arrows and page regions are never what anyone is looking for.
            let children = attrs.role == "AXScrollBar" ? [] : attrs.children

            if attrs.role == "AXRow", rowTexts == nil {
                let ref = takeRef(element)
                table[ref] = element
                let at = lines.count
                lines.append(nil)
                rowTexts = []
                if depth < limits.maxDepth {
                    walkChildren(children, depth: depth, printDepth: printDepth + 1)
                }
                let joined = UINode.clean((rowTexts ?? []).joined(separator: " | "), limit: 200)
                rowTexts = nil
                // A separator: no text and nothing printed beneath it.
                if joined == nil, attrs.description == nil, lines.count == at + 1 {
                    lines.removeLast()
                    table.removeValue(forKey: ref)
                    return
                }
                var node = UINode(ref: ref, depth: printDepth, role: "AXRow", title: joined, value: nil, description: attrs.description,
                                  frame: frame, enabled: attrs.enabled, focused: false, pressable: false)
                node.offscreen = offscreen
                node.selected = attrs.selected
                lines[at] = node
                return
            }
            // Inside a row, plain text belongs to the row's line; controls still get their own.
            if rowTexts != nil, ["AXStaticText", "AXTextField", "AXCell", "AXImage"].contains(attrs.role) {
                if let text = attrs.value ?? attrs.title, attrs.role != "AXCell", attrs.role != "AXImage" { rowTexts?.append(text) }
                if depth < limits.maxDepth {
                    walkChildren(children, depth: depth, printDepth: printDepth)
                }
                return
            }
            if attrs.role == "AXStaticText", let text = attrs.value ?? attrs.title {
                siblingTexts[siblingTexts.count - 1].append((text, frame))
            }

            var childDepth = printDepth
            if UINode.isWorthEmitting(role: attrs.role, title: attrs.title, value: attrs.value, description: attrs.description) {
                let ref = takeRef(element)
                table[ref] = element
                var node = UINode(ref: ref, depth: printDepth, role: attrs.role, subrole: attrs.subrole, title: attrs.title, value: attrs.value,
                                  description: attrs.description, frame: frame, enabled: attrs.enabled, focused: attrs.focused)
                if UINode.pressCandidates.contains(attrs.role) { node.pressable = Self.supportsPress(element) }
                if attrs.title == nil, attrs.description == nil, Self.needsLabel.contains(attrs.role) {
                    node.label = Self.inferredLabel(for: attrs, precedingTexts: siblingTexts.last ?? [])
                }
                node.offscreen = offscreen
                node.selected = attrs.selected
                lines.append(node)
                childDepth += 1
            }
            guard depth < limits.maxDepth else { return }
            walkChildren(children, depth: depth, printDepth: childDepth)
        }
        walk(root, depth: 0, printDepth: 0)
        refs[windowID] = table
        lastRefNumber[windowID] = next - 1

        var nodes = lines.compactMap { $0 }
        let scanned = nodes.count
        if let query = limits.query {
            // A query answers with the matches alone, flat: depth only means something in a whole tree.
            nodes = Array(nodes.filter(query.matches).prefix(query.limit)).map { node in
                var flat = node
                flat.depth = 0
                return flat
            }
        }
        var result: [String: Any] = ["windowId": Int(windowID), "count": nodes.count, "outline": nodes.map(\.line).joined(separator: "\n")]
        if limits.query != nil { result["scanned"] = scanned }
        if let truncated {
            result["truncated"] = truncated
        }
        return result
    }

    private struct Attributes {
        var role = "AXUnknown"
        var subrole: String?
        var title: String?
        var value: String?
        var description: String?
        var frame: CGRect?
        var enabled = true
        var focused = false
        var children: [AXUIElement] = []
        var unresponsive = false
        var selected = false
        var titleElement: AXUIElement?
    }

    // Controls that are useless without knowing what they control.
    private static let needsLabel: Set<String> = ["AXCheckBox", "AXRadioButton", "AXComboBox", "AXPopUpButton", "AXSlider", "AXTextField", "AXTextArea"]

    /// A switch in System Settings has no title of its own; the text beside it
    /// is a sibling. Prefer the app's AXTitleUIElement, else the nearest
    /// preceding sibling text on the same line.
    private static func inferredLabel(for attrs: Attributes, precedingTexts: [(text: String, frame: CGRect?)]) -> String? {
        if let element = attrs.titleElement {
            let t = copyAttributes(element)
            if let label = t.value ?? t.title { return label }
        }
        guard let frame = attrs.frame else { return nil }
        let sameLine = precedingTexts.last { candidate in
            guard let f = candidate.frame else { return false }
            return f.minY < frame.maxY && f.maxY > frame.minY - 4
        }
        return sameLine?.text ?? precedingTexts.last?.text
    }

    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXChildrenAttribute,
        kAXSelectedAttribute, kAXTitleUIElementAttribute,
    ]

    private static func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction)
    }

    // One IPC round trip per node instead of ten.
    private static func copyAttributes(_ element: AXUIElement) -> Attributes {
        var out = Attributes()
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, attributeNames as CFArray, [], &valuesRef)
        out.unresponsive = err == .cannotComplete
        guard err == .success, let values = valuesRef as? [Any], values.count == attributeNames.count else {
            return out
        }
        out.role = values[0] as? String ?? "AXUnknown"
        let subrole = values[1] as? String
        out.subrole = subrole
        out.title = UINode.clean(values[2] as? String)
        // Never read a password field back.
        if subrole != "AXSecureTextField" {
            if let s = values[3] as? String {
                out.value = UINode.clean(s)
            } else if let n = values[3] as? NSNumber {
                out.value = n.stringValue
            }
        }
        out.description = UINode.clean(values[4] as? String)
        var point = CGPoint.zero
        var size = CGSize.zero
        if CFGetTypeID(values[5] as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(values[6] as CFTypeRef) == AXValueGetTypeID(),
           AXValueGetValue(values[5] as! AXValue, .cgPoint, &point), AXValueGetValue(values[6] as! AXValue, .cgSize, &size) {
            out.frame = CGRect(origin: point, size: size)
        }
        out.enabled = values[7] as? Bool ?? true
        out.focused = values[8] as? Bool ?? false
        out.children = values[9] as? [AXUIElement] ?? []
        out.selected = values[10] as? Bool ?? false
        if CFGetTypeID(values[11] as CFTypeRef) == AXUIElementGetTypeID() {
            out.titleElement = (values[11] as! AXUIElement)
        }
        return out
    }

    // MARK: - Refs

    func element(for ref: String) throws -> AXUIElement {
        guard let wid = UInt32(ref.split(separator: ":").first ?? ""), let element = refs[wid]?[ref] else {
            throw UIError.unknownRef(ref)
        }
        return element
    }

    private func touch(_ windowID: UInt32) {
        refOrder.removeAll { $0 == windowID }
        refOrder.append(windowID)
        while refOrder.count > maxTrackedWindows {
            let evicted = refOrder.removeFirst()
            refs.removeValue(forKey: evicted)
            roots.removeValue(forKey: evicted)
        }
    }

    // MARK: - Actions (call on `queue`)

    /// AXPress. Returns how it was done. The return code is not the verdict:
    /// Finder's disclosure triangles answer AXPress with an error (-25205) and
    /// expand anyway, so for those the row's state before and after decides.
    /// Only if nothing changed is the row's AXDisclosing attribute set directly.
    @discardableResult
    func press(_ ref: String) throws -> String {
        let element = try element(for: ref)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let row = role as? String == "AXDisclosureTriangle" ? Self.ancestor(of: element, role: "AXRow") : nil
        let before = row.flatMap(Self.isDisclosing)

        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if err == .success { return "AXPress" }
        if let row, let before {
            Thread.sleep(forTimeInterval: 0.1)
            if Self.isDisclosing(row) != before { return "AXPress (reported error \(err.rawValue), took effect)" }
            let next: CFBoolean = before ? kCFBooleanFalse : kCFBooleanTrue
            if AXUIElementSetAttributeValue(row, kAXDisclosingAttribute as CFString, next) == .success { return "AXDisclosing" }
        }
        throw UIError.axFailed("AXPress", err)
    }

    private static func isDisclosing(_ row: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(row, kAXDisclosingAttribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func ancestor(of element: AXUIElement, role wanted: String, maxHops: Int = 6) -> AXUIElement? {
        var current = element
        for _ in 0..<maxHops {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return nil }
            current = next as! AXUIElement
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if role as? String == wanted { return current }
        }
        return nil
    }

    func setValue(_ ref: String, _ value: String, allowSecure: Bool = false) throws {
        let element = try element(for: ref)
        if !allowSecure, Self.isSecureField(element) { throw UIError.secureField }
        // Sliders, scroll bars, checkboxes and disclosure triangles hold numbers
        // and reject a string, so match the type the element has now.
        var current: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &current)
        var typed: CFTypeRef = value as CFString
        if current is NSNumber, let number = Double(value) {
            // Whole numbers go as integers: Finder accepts a Double 1.0 and ignores it.
            typed = Int(exactly: number).map { NSNumber(value: $0) } ?? NSNumber(value: number)
        }
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, typed)
        guard err == .success else { throw UIError.axFailed("set AXValue", err) }
    }

    static func isSecureField(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String == "AXSecureTextField"
    }

    /// Is the keyboard focus of app `pid` in a password field?
    static func focusIsSecureField(pid: pid_t) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(makeAppElement(pid: pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        return isSecureField(element as! AXUIElement)
    }

    /// Select a row, tab or list item (AXSelected), the way a click on it would.
    func select(_ ref: String) throws {
        let err = AXUIElementSetAttributeValue(try element(for: ref), kAXSelectedAttribute as CFString, kCFBooleanTrue)
        guard err == .success else { throw UIError.axFailed("set AXSelected", err) }
    }

    /// Scroll the element's container until it is visible.
    @discardableResult
    func scrollTo(_ ref: String) throws -> String {
        let element = try element(for: ref)
        let err = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        if err == .success { return "AXScrollToVisible" }
        // Nothing to do is not a failure.
        if let area = Self.ancestor(of: element, role: "AXScrollArea", maxHops: 10),
           let view = Self.copyAttributes(area).frame, let target = Self.copyAttributes(element).frame, view.contains(target) {
            return "already visible"
        }
        // Finder's rows do not take the action. Drive the scroll area's own bar instead:
        // put the node's centre at the middle of the viewport.
        guard let area = Self.ancestor(of: element, role: "AXScrollArea", maxHops: 10),
              let view = Self.copyAttributes(area).frame, let target = Self.copyAttributes(element).frame else {
            throw UIError.axFailed("AXScrollToVisible", err)
        }
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXVerticalScrollBarAttribute as CFString, &barRef) == .success,
              let barValue = barRef, CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
            throw UIError.axFailed("AXScrollToVisible", err)
        }
        let bar = barValue as! AXUIElement
        // The document is the scroll area's tallest child; its frame moves as the bar does.
        guard let document = Self.copyAttributes(area).children.compactMap({ Self.copyAttributes($0).frame }).max(by: { $0.height < $1.height }),
              document.height > view.height else {
            throw UIError.axFailed("AXScrollToVisible", err)
        }
        let wantedTop = target.midY - document.minY - view.height / 2
        let fraction = min(max(wantedTop / (document.height - view.height), 0), 1)
        let set = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(fraction)))
        guard set == .success else { throw UIError.axFailed("scroll bar AXValue", set) }
        return "scrollbar"
    }

    /// The element's whole value, unclipped apart from a size ceiling: a text
    /// view's AXValue is the entire document. Password fields are never read.
    func value(of ref: String, limit: Int = 65_536) throws -> (text: String, truncated: Bool) {
        let element = try element(for: ref)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if subrole as? String == "AXSecureTextField" { return ("", false) }
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw)
        guard err == .success else { throw UIError.axFailed("read AXValue", err) }
        let text = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? ""
        return text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
    }

    /// Center of the element's current frame, re-read so a moved window still clicks true.
    func center(of ref: String) throws -> CGPoint {
        guard let f = Self.copyAttributes(try element(for: ref)).frame, f.width > 0, f.height > 0 else {
            throw UIError.noFrame(ref)
        }
        return CGPoint(x: f.midX, y: f.midY)
    }

    // MARK: - Focus truth

    enum FocusCheck: Equatable {
        case held
        /// Something else has focus; the string says what.
        case elsewhere(String)
        /// The OS would not say (hung app, AX timeout). Never treated as held.
        case unknown(String)
    }

    /// Does `window` of app `pid` hold keyboard focus right now, according to
    /// the OS? GridState's focusedWindowID is optimistic and cannot answer this.
    /// Elements are compared directly, so a window with no CG ID (Ghostty) works.
    static func checkFocus(pid: pid_t, window: AXUIElement) -> FocusCheck {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Decide on the pid first: AX against our own pid must never run here.
        guard frontmost == pid else {
            return verdict(frontmostPid: frontmost, targetPid: pid, focusedIsTarget: nil)
        }
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(makeAppElement(pid: pid), kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return verdict(frontmostPid: frontmost, targetPid: pid, focusedIsTarget: nil)
        }
        return verdict(frontmostPid: frontmost, targetPid: pid, focusedIsTarget: CFEqual(focused, window))
    }

    /// `focusedIsTarget` is nil when the app's focused window could not be read.
    static func verdict(frontmostPid: pid_t?, targetPid: pid_t, focusedIsTarget: Bool?) -> FocusCheck {
        guard let frontmostPid else { return .unknown("no frontmost app") }
        guard frontmostPid == targetPid else { return .elsewhere("pid \(frontmostPid) is frontmost") }
        switch focusedIsTarget {
        case .some(true): return .held
        case .some(false): return .elsewhere("another window of the app has focus")
        case .none: return .unknown("the app did not report its focused window")
        }
    }

    /// The CG window ID an AX window element resolves to, if any.
    static func windowID(of element: AXUIElement) -> UInt32? {
        var wid: UInt32 = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }
}
