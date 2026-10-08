// Holds the user's clipboard in memory while a test writes to the pasteboard, then puts it back.
//
//     swift scripts/clipboard-guard.swift        (the integration suite starts it; commands on stdin)
//
// On start it copies every item and every type of the general pasteboard into this process's
// memory -- never to disk -- and prints "saved <items> items <types> types <bytes> bytes".
// Commands, one per line:
//     conceal TEXT     put TEXT on the pasteboard marked org.nspasteboard.ConcealedType
//     transient TEXT   the same with org.nspasteboard.TransientType
//     restore          put the saved contents back, read them back to verify, print the verdict, exit
// EOF on stdin restores too, so a crashed test still gives the clipboard back.
// It prints sizes and type counts only, never contents.
import AppKit

// CLIPBOARD_GUARD_PASTEBOARD names a private pasteboard instead, for testing this script itself.
let board = ProcessInfo.processInfo.environment["CLIPBOARD_GUARD_PASTEBOARD"].map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? NSPasteboard.general
let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
}
let savedBytes = saved.flatMap { $0 }.reduce(0) { $0 + $1.1.count }
// Types but no data means the contents could not be copied: say so and let nothing be written.
if saved.flatMap({ $0 }).isEmpty, !(board.types ?? []).isEmpty {
    print("cannot save: \((board.types ?? []).count) types, no readable data")
    exit(2)
}
print("saved \(saved.count) items \(saved.flatMap { $0 }.count) types \(savedBytes) bytes")
fflush(stdout)

func restore() -> Bool {
    board.clearContents()
    let items: [NSPasteboardItem] = saved.map { types in
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        return item
    }
    if !items.isEmpty, !board.writeObjects(items) { return false }
    // Read back: same items, same types, same bytes.
    let now = board.pasteboardItems ?? []
    guard now.count == saved.count else { return false }
    for (item, types) in zip(now, saved) {
        for (type, data) in types where item.data(forType: type) != data { return false }
    }
    return true
}

func mark(_ text: String, _ marker: String) {
    board.clearContents()
    board.setString(text, forType: .string)
    board.setString("", forType: NSPasteboard.PasteboardType(marker))
    print("marked \(text.utf8.count) bytes")
    fflush(stdout)
}

while let line = readLine() {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first {
    case "conceal": mark(parts.count > 1 ? parts[1] : "", "org.nspasteboard.ConcealedType")
    case "transient": mark(parts.count > 1 ? parts[1] : "", "org.nspasteboard.TransientType")
    case "restore":
        let ok = restore()
        print(ok ? "restored verified \(savedBytes) bytes" : "RESTORE FAILED")
        exit(ok ? 0 : 1)
    default: break
    }
}
let ok = restore()
print(ok ? "restored verified \(savedBytes) bytes (stdin closed)" : "RESTORE FAILED")
exit(ok ? 0 : 1)
