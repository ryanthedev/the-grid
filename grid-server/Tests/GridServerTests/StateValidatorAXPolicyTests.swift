import XCTest
import ApplicationServices

@testable import GridServer

// Tests for StateValidator's AX-failure classification.
//
// Written to close a mutation-testing gap: a 200-mutant campaign scored
// StateValidator at 0% — all 12 compilable mutants survived. The most dangerous
// of them flipped the branch that decides how to treat a failed kAXWindows
// query. That branch is the only thing standing between "this app owns no
// windows" and "this app did not answer", and inverting it makes every window
// of an unresponsive app look orphaned, so all of them are pruned after two
// validation cycles.
//
// The decision was inlined in the private actor method getAXWindowIDs(pid:) and
// therefore untestable. It is now a pure static — mirroring the same extraction
// StateManager.shouldUseSoleWindowFallback already uses — so the semantics can
// be pinned here without an AX connection.
final class StateValidatorAXPolicyTests: XCTestCase {

    // .attributeUnsupported is definitive: the process does not implement the
    // windows attribute at all (an agent or daemon), so an empty set is an
    // accurate answer and pruning on it is correct.
    func test_attributeUnsupported_meansGenuinelyNoWindows() {
        XCTAssertTrue(
            StateValidator.axFailureMeansNoWindows(.attributeUnsupported),
            "a non-windowed process genuinely has no windows"
        )
    }

    // Everything else means we learned nothing. Absence of evidence must not be
    // treated as evidence of absence, or a busy app loses all of its windows.
    func test_transientFailures_meanUnknown_notEmpty() {
        let transient: [AXError] = [
            .cannotComplete,
            .notImplemented,
            .apiDisabled,
            .invalidUIElement,
            .noValue,
            .failure,
            .attributeUnsupported,
        ]

        for err in transient where err != .attributeUnsupported {
            XCTAssertFalse(
                StateValidator.axFailureMeansNoWindows(err),
                "\(err) is not evidence that the app has no windows — it must not license a prune"
            )
        }
    }

    // .cannotComplete is the specific code an unresponsive or beachballing app
    // returns, and is the most consequential single case: treating it as "no
    // windows" prunes every window that app owns.
    func test_cannotComplete_neverLicensesAPrune() {
        XCTAssertFalse(
            StateValidator.axFailureMeansNoWindows(.cannotComplete),
            "a busy app must be skipped, never pruned"
        )
    }

    // .success is not a failure code and should never be classified as
    // "no windows" — the caller only consults this on the guard-else path, but
    // the classifier must not claim emptiness if it is ever reached with success.
    func test_success_isNotTreatedAsNoWindows() {
        XCTAssertFalse(StateValidator.axFailureMeansNoWindows(.success))
    }
}
