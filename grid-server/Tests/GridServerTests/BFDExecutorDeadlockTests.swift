import XCTest
@testable import GridServer

/// DW-7.10 (#38): a hotkey command that emits more than the ~64KB pipe buffer
/// must not deadlock or be false-killed by the 30s timeout. Reading the pipes
/// concurrently with waitUntilExit is the fix.
final class BFDExecutorDeadlockTests: XCTestCase {

    func test_DW_7_10_large_output_completes_without_deadlock() {
        var config = BFDConfig()
        config.shell = "/bin/sh"
        let executor = BFDExecutor(config: config)

        // Emit ~512KB to stdout — well past the 64KB pipe buffer that would
        // deadlock the old waitUntilExit-then-read ordering.
        let command = "yes ABCDEFGHIJ | head -c 524288"

        let exp = expectation(description: "execute returns")
        DispatchQueue.global().async {
            executor.execute(hotkey: "test", command: command)
            exp.fulfill()
        }
        // Must finish FAR under the 30s command timeout. If the pipe deadlocks,
        // this times out.
        wait(for: [exp], timeout: 10)
    }

    func test_DW_7_10_large_stderr_completes_without_deadlock() {
        var config = BFDConfig()
        config.shell = "/bin/sh"
        let executor = BFDExecutor(config: config)
        // Push the big payload to stderr to exercise the second reader.
        let command = "yes ABCDEFGHIJ | head -c 524288 1>&2"

        let exp = expectation(description: "execute returns")
        DispatchQueue.global().async {
            executor.execute(hotkey: "test", command: command)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}
