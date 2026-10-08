import XCTest
@testable import GridServer

final class MenuAutomationTests: XCTestCase {
    func testShortcutIsWrittenTheWayKeyPressReadsIt() {
        XCTAssertEqual(MenuAutomation.shortcut(char: "P", modifiers: 1, virtualKey: nil, glyph: nil), "cmd+shift+P")
        XCTAssertEqual(MenuAutomation.shortcut(char: "H", modifiers: 2, virtualKey: nil, glyph: nil), "cmd+alt+H")
        // Bit 3 means "no command key"; bit 4 is fn (Window > Fill is fn+ctrl+F = 28).
        XCTAssertEqual(MenuAutomation.shortcut(char: "F", modifiers: 28, virtualKey: nil, glyph: nil), "ctrl+fn+F")
        // Finder's Move to Trash: an empty character, a keycode and a glyph.
        XCTAssertEqual(MenuAutomation.shortcut(char: "", modifiers: 0, virtualKey: 51, glyph: 23), "cmd+backspace")
        XCTAssertEqual(MenuAutomation.shortcut(char: nil, modifiers: 0, virtualKey: nil, glyph: 0x70), "cmd+f2")
        // Modifiers without a key are not a shortcut.
        XCTAssertNil(MenuAutomation.shortcut(char: nil, modifiers: 8, virtualKey: nil, glyph: nil))
        XCTAssertNil(MenuAutomation.shortcut(char: nil, modifiers: 0, virtualKey: nil, glyph: nil))
        // What it prints must parse as a key combo.
        XCTAssertNoThrow(try parseKeyCombo("cmd+shift+P"))
        XCTAssertNoThrow(try parseKeyCombo("cmd+backspace"))
    }

    func testEntryLineAndFilter() {
        var pdf = MenuEntry(path: ["File", "Export As", "PDF…"], shortcut: "cmd+shift+P", enabled: true)
        XCTAssertEqual(pdf.line, "File > Export As > PDF…  [cmd+shift+P]  enabled")
        pdf.checked = true
        XCTAssertEqual(MenuEntry(path: ["Edit", "Undo"], shortcut: nil, enabled: false).line, "Edit > Undo  disabled")
        XCTAssertTrue(pdf.line.hasSuffix("enabled  checked"))

        XCTAssertTrue(pdf.matches(text: "export as > pdf...", enabled: nil))
        XCTAssertTrue(pdf.matches(text: "CMD+SHIFT", enabled: true))
        XCTAssertFalse(pdf.matches(text: "pdf", enabled: false))
        XCTAssertFalse(pdf.matches(text: "print", enabled: nil))
    }

    func testPathMatchingIgnoresCaseAndEllipsisSpelling() {
        XCTAssertEqual(MenuPath.parse(" File>Export As  >  PDF… "), ["File", "Export As", "PDF…"])
        XCTAssertTrue(MenuPath.parse(" > ").isEmpty)
        let titles = ["Save", "Save As…", "Find", "Find…"]
        XCTAssertEqual(MenuPath.matches("save as...", among: titles), [1])
        XCTAssertEqual(MenuPath.matches("SAVE AS", among: titles), [1])
        // An exact title wins over one that only differs by its ellipsis.
        XCTAssertEqual(MenuPath.matches("find", among: titles), [2])
        XCTAssertEqual(MenuPath.matches("find…", among: titles), [3])
        XCTAssertTrue(MenuPath.matches("sav", among: titles).isEmpty)
        // Alternates share a title; the caller chooses among them.
        XCTAssertEqual(MenuPath.matches("Eject", among: ["Eject", "Eject", "Find"]), [0, 1])
    }

    func testAppNamesAreComparedWithoutInvisibleMarks() {
        XCTAssertEqual(MenuAutomation.plain("\u{200E}WhatsApp "), "whatsapp")
        XCTAssertEqual(MenuAutomation.plainName("\u{200E}WhatsApp"), "WhatsApp")
        XCTAssertNil(MenuAutomation.plainName("\u{200E}"))
        XCTAssertNil(MenuAutomation.runningApp(named: "No Such App 9f3"))
    }

    func testErrorsSayWhatExists() {
        let missing = MenuError.noSuchItem(wanted: "Exprt", under: "'File'", siblings: ["New", "Open…"]).description
        XCTAssertTrue(missing.contains("no menu item 'Exprt' under 'File'") && missing.contains("New, Open…"))
        XCTAssertTrue(MenuError.disabled(path: "Edit > Undo", app: "TextEdit").description.contains("is disabled in TextEdit"))
    }
}
