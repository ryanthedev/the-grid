import XCTest
@testable import GridServer

final class FatalFormatterTests: XCTestCase {

    // DW-1.1 / DW-1.2: verify the exact bytes the async-signal-safe path produces.
    // This test isolates the formatter from actual signal delivery so we can
    // assert the wire format precisely.
    func test_formats_SIGSEGV_line_with_pid_uptime_and_ts() {
        let bytes = FatalFormatter.formatFatal(
            sig: SIGSEGV,
            pid: 12345,
            uptimeSec: 67,
            nowUnix: 1_700_000_000
        )
        let line = String(decoding: bytes, as: UTF8.self)

        XCTAssertTrue(line.hasSuffix("\n"), "line must end with newline: \(line)")
        XCTAssertTrue(line.contains("\"ev\":\"srv.fatal\""), "missing ev: \(line)")
        XCTAssertTrue(line.contains("\"sig\":\"SIGSEGV\""), "missing sig: \(line)")
        XCTAssertTrue(line.contains("\"pid\":12345"), "missing pid: \(line)")
        XCTAssertTrue(line.contains("\"uptime\":67"), "missing uptime: \(line)")
        XCTAssertTrue(line.contains("\"ts\":1700000000"), "missing ts: \(line)")
    }

    func test_formats_SIGABRT_signal_name() {
        let bytes = FatalFormatter.formatFatal(
            sig: SIGABRT,
            pid: 1,
            uptimeSec: 0,
            nowUnix: 1
        )
        let line = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(line.contains("\"sig\":\"SIGABRT\""), "got: \(line)")
    }

    func test_all_six_fatal_signals_have_names() {
        let sigs: [(Int32, String)] = [
            (SIGSEGV, "SIGSEGV"),
            (SIGABRT, "SIGABRT"),
            (SIGILL,  "SIGILL"),
            (SIGBUS,  "SIGBUS"),
            (SIGFPE,  "SIGFPE"),
            (SIGPIPE, "SIGPIPE"),
        ]
        for (n, name) in sigs {
            let bytes = FatalFormatter.formatFatal(sig: n, pid: 1, uptimeSec: 0, nowUnix: 0)
            let line = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(line.contains("\"sig\":\"\(name)\""), "expected \(name), got: \(line)")
        }
    }
}
