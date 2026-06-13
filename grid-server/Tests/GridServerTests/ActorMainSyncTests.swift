import XCTest
import Foundation
@testable import GridServer

/// DW-7.5 (#44): the StateManager actor must never call DispatchQueue.main.sync
/// — blocking a cooperative-pool thread on the main queue violates Swift
/// concurrency's forward-progress contract and stalls every command/event
/// awaiting the actor. removeObserver now uses `await MainActor.run`. This is a
/// structural test (no live actor harness): assert the call form is absent from
/// the StateManager source, mirroring EventAllowlistTests' source-scan approach.
final class ActorMainSyncTests: XCTestCase {

    func test_DW_7_5_statemanager_has_no_main_sync_call() throws {
        var url = URL(fileURLWithPath: #file)
        // Tests/GridServerTests/ActorMainSyncTests.swift -> package root.
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("Sources/GridServer/StateManager.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        // Strip line comments so the explanatory comment that names the
        // anti-pattern does not trip the check.
        let codeOnly = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let r = line.range(of: "//") {
                    return String(line[line.startIndex..<r.lowerBound])
                }
                return String(line)
            }
            .joined(separator: "\n")

        // The actual blocking call form is `DispatchQueue.main.sync {`.
        XCTAssertFalse(
            codeOnly.contains("DispatchQueue.main.sync"),
            "StateManager must use `await MainActor.run`, not DispatchQueue.main.sync (#44)")
    }

    func test_DW_7_5_remove_observer_uses_main_actor_run() throws {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("Sources/GridServer/StateManager.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        // Positive assertion: the safe pattern is present.
        XCTAssertTrue(source.contains("await MainActor.run"),
                      "removeObserver/observer-stop must run via await MainActor.run")
    }
}
