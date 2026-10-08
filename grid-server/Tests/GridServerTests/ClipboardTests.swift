import AppKit
import XCTest
@testable import GridServer

final class ClipboardTests: XCTestCase {
    func testConcealedAndTransientClipboardsAreNeverRead() {
        let text = NSPasteboard.PasteboardType.string.rawValue
        XCTAssertEqual(ClipboardPolicy.readDecision(types: [text]), .read)
        XCTAssertEqual(ClipboardPolicy.readDecision(types: ["public.html", text, "public.rtf"]), .read)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            guard case .refuse(let why) = ClipboardPolicy.readDecision(types: [text, marker]) else { return XCTFail("\(marker) was read") }
            XCTAssertTrue(why.contains(marker))
            // The marker alone is enough, wherever it sits and whatever else is there.
            XCTAssertNotEqual(ClipboardPolicy.readDecision(types: [marker, "public.png"]), .noText)
        }
        XCTAssertEqual(ClipboardPolicy.readDecision(types: ["public.png", "public.tiff"]), .noText)
        XCTAssertEqual(ClipboardPolicy.readDecision(types: []), .noText)
    }

    func testClipCutsAtSixtyFourKilobytesOnACharacterBoundary() {
        XCTAssertEqual(ClipboardPolicy.maxReadBytes, 65_536)
        let small = ClipboardPolicy.clip("héllo ✓")
        XCTAssertTrue(small.text == "héllo ✓" && !small.truncated)
        // Three bytes each: a cut in the middle of one would not be a string.
        let big = ClipboardPolicy.clip(String(repeating: "✓", count: 30_000))
        XCTAssertTrue(big.truncated)
        XCTAssertEqual(big.text.count, 21_845)
        XCTAssertLessThanOrEqual(big.text.utf8.count, 65_536)
        XCTAssertEqual(ClipboardPolicy.clip("abcdef", limit: 4).text, "abcd")
    }

    /// A private, uniquely named pasteboard: a test must never touch the user's clipboard.
    func testRoundTripOnAPrivatePasteboardReportsChangeCountAndSize() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let written = try Clipboard.write("grid ✓ test", to: board)
        XCTAssertEqual(written["bytes"] as? Int, 13)
        XCTAssertGreaterThan(written["changeCount"] as! Int, written["previousChangeCount"] as! Int)
        let read = try Clipboard.read(from: board)
        XCTAssertEqual(read["text"] as? String, "grid ✓ test")
        XCTAssertEqual(read["changeCount"] as? Int, written["changeCount"] as? Int)
        XCTAssertNil(read["truncated"])

        _ = try Clipboard.write(String(repeating: "x", count: 100_000), to: board)
        let long = try Clipboard.read(from: board)
        XCTAssertEqual(long["truncated"] as? Bool, true)
        XCTAssertEqual(long["bytes"] as? Int, 100_000)
        XCTAssertEqual((long["text"] as? String)?.count, 65_536)
        XCTAssertThrowsError(try Clipboard.write(String(repeating: "x", count: ClipboardPolicy.maxWriteBytes + 1), to: board))
    }

    func testAConcealedItemIsRefusedAndItsTextIsNotInTheError() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("hunter2", forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType(ClipboardPolicy.concealedType))
        XCTAssertThrowsError(try Clipboard.read(from: board)) { error in
            XCTAssertTrue("\(error)".contains("clip.read refused"))
            XCTAssertFalse("\(error)".contains("hunter2"))
        }
    }
}
