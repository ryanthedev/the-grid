import XCTest
@testable import GridServer

final class PrevExitClassifierTests: XCTestCase {

    // DW-1.4: classify by the last terminal event after the most recent srv.start.

    func test_classifies_graceful_when_shutdown_done_is_last() {
        let tail = """
        {"ev":"srv.start","ts":1700000000}
        {"ev":"bdr.init","ts":1700000001}
        {"ev":"srv.shutdown.done","ts":1700000002}
        """
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: tail), .graceful)
    }

    func test_classifies_fatal_when_srv_fatal_is_last() {
        let tail = """
        {"ev":"srv.start","ts":1700000000}
        {"ev":"srv.fatal","data":{"sig":"SIGSEGV","pid":123,"uptime":5},"ts":1700000005}
        """
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: tail), .fatal)
    }

    func test_classifies_fatal_when_exception_is_last() {
        let tail = """
        {"ev":"srv.start","ts":1700000000}
        {"ev":"srv.fatal.exception","data":{"name":"X","reason":"y"},"ts":1700000005}
        """
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: tail), .fatal)
    }

    func test_classifies_unknown_when_only_srv_start_with_no_terminal() {
        let tail = """
        {"ev":"srv.start","ts":1700000000}
        {"ev":"bdr.init","ts":1700000001}
        {"ev":"focus.mismatch","ts":1700000002}
        """
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: tail), .unknown)
    }

    func test_classifies_unknown_on_empty() {
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: ""), .unknown)
    }

    func test_tolerates_partial_last_line() {
        // Simulates reading mid-line from an 8KB tail window.
        let tail = """
        {"ev":"srv.sta
        {"ev":"srv.start","ts":1700000000}
        {"ev":"srv.shutdown.done","ts":1700000002}
        """
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: tail), .graceful)
    }

    func test_ignores_terminal_events_before_most_recent_srv_start() {
        // Previous run was fatal, but then a new srv.start appeared with no
        // subsequent terminal event — which means THIS is the classifier run
        // after the previous unknown exit. Expected: unknown, because we key
        // off the last srv.start.
        //
        // Note: in practice the classifier is invoked BEFORE the current run's
        // own srv.start is written, so the "last" srv.start is the previous
        // run's. This test documents the contract for that case.
        let tail = """
        {"ev":"srv.start","ts":1700000000}
        {"ev":"srv.fatal","ts":1700000005}
        {"ev":"srv.start","ts":1700000010}
        """
        XCTAssertEqual(PrevExitClassifier.classify(jsonlTail: tail), .unknown)
    }
}
