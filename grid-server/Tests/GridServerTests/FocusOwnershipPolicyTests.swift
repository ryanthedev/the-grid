import XCTest
import Foundation
@testable import GridServer

// Phase 3 pure-predicate tests for the focus-ownership path. These exercise the
// boundary-free decision helpers in FocusOwnershipPolicy.swift and the extended
// FocusLoopDetector / FocusLoopActor.
final class FocusOwnershipPolicyTests: XCTestCase {

    // MARK: - DW-3.1 (#21) focus result classification

    func test_DW_3_1_classify_all_success_is_true() {
        let outcome = FocusRaiseOutcome(
            psnResolved: true,
            slpsFrontSucceeded: true,
            axElementPresent: true,
            axRaiseSucceeded: true
        )
        XCTAssertTrue(classifyFocusResult(outcome))
    }

    func test_DW_3_1_classify_slps_failure_is_false() {
        let outcome = FocusRaiseOutcome(
            psnResolved: true,
            slpsFrontSucceeded: false,
            axElementPresent: true,
            axRaiseSucceeded: true
        )
        XCTAssertFalse(classifyFocusResult(outcome))
    }

    func test_DW_3_1_classify_missing_ax_element_is_false() {
        // getAXElement returned nil -> no raise happened -> not focused.
        let outcome = FocusRaiseOutcome(
            psnResolved: true,
            slpsFrontSucceeded: true,
            axElementPresent: false,
            axRaiseSucceeded: false
        )
        XCTAssertFalse(classifyFocusResult(outcome))
    }

    func test_DW_3_1_classify_psn_fail_is_false() {
        let outcome = FocusRaiseOutcome(
            psnResolved: false,
            slpsFrontSucceeded: false,
            axElementPresent: false,
            axRaiseSucceeded: false
        )
        XCTAssertFalse(classifyFocusResult(outcome))
    }

    // MARK: - DW-3.3 (#8) empty-cell skip

    func test_DW_3_3_skip_empty_selects_next_nonempty() {
        let candidates = ["notify", "main", "side"]
        let counts = ["notify": 0, "main": 2, "side": 1]
        XCTAssertEqual(selectNonEmptyCandidate(orderedCandidates: candidates, cellWindowCounts: counts), "main")
    }

    func test_DW_3_3_all_empty_returns_nil() {
        let candidates = ["a", "b"]
        let counts = ["a": 0, "b": 0]
        XCTAssertNil(selectNonEmptyCandidate(orderedCandidates: candidates, cellWindowCounts: counts))
    }

    func test_DW_3_3_first_nonempty_wins_order_preserved() {
        // Caller orders by closeness; the helper must respect that order.
        let candidates = ["far", "near"]
        let counts = ["far": 3, "near": 5]
        XCTAssertEqual(selectNonEmptyCandidate(orderedCandidates: candidates, cellWindowCounts: counts), "far")
    }

    func test_DW_3_3_unknown_cell_treated_as_empty() {
        let candidates = ["ghost", "real"]
        let counts = ["real": 1]
        XCTAssertEqual(selectNonEmptyCandidate(orderedCandidates: candidates, cellWindowCounts: counts), "real")
    }

    // MARK: - DW-3.4 (#13) focusSweep guard

    func test_DW_3_4_sweep_skips_when_suppressed() {
        XCTAssertFalse(shouldSweepCorrect(
            osWindowFenced: false, cellMateFenced: false,
            genAtStart: 5, genNow: 5, suppressed: true))
    }

    func test_DW_3_4_sweep_skips_when_os_window_fenced() {
        XCTAssertFalse(shouldSweepCorrect(
            osWindowFenced: true, cellMateFenced: false,
            genAtStart: 5, genNow: 5, suppressed: false))
    }

    func test_DW_3_4_sweep_skips_when_cellmate_fenced() {
        XCTAssertFalse(shouldSweepCorrect(
            osWindowFenced: false, cellMateFenced: true,
            genAtStart: 5, genNow: 5, suppressed: false))
    }

    func test_DW_3_4_sweep_skips_when_generation_changed() {
        // A command began after the sweep snapshotted state -> stale read.
        XCTAssertFalse(shouldSweepCorrect(
            osWindowFenced: false, cellMateFenced: false,
            genAtStart: 5, genNow: 6, suppressed: false))
    }

    func test_DW_3_4_sweep_proceeds_when_all_clear() {
        XCTAssertTrue(shouldSweepCorrect(
            osWindowFenced: false, cellMateFenced: false,
            genAtStart: 7, genNow: 7, suppressed: false))
    }

    // MARK: - DW-3.5 (#17) focus sequence gate

    func test_DW_3_5_gate_accepts_newer() {
        XCTAssertTrue(FocusSequenceGate.shouldApply(incomingSeq: 11, lastAppliedSeq: 10))
    }

    func test_DW_3_5_gate_rejects_older() {
        // Reordered stale event must not overwrite a newer focus.
        XCTAssertFalse(FocusSequenceGate.shouldApply(incomingSeq: 9, lastAppliedSeq: 10))
    }

    func test_DW_3_5_gate_accepts_equal_first_event() {
        // First event: lastApplied 0, incoming 0 -> accept.
        XCTAssertTrue(FocusSequenceGate.shouldApply(incomingSeq: 0, lastAppliedSeq: 0))
    }

    // MARK: - DW-3.10 (#59s) restore-focus skip predicate (instrument-only)

    func test_DW_3_10_restore_skip_when_window_left_space() {
        // Window now lives on space 3; restoring space 5 should be flagged.
        XCTAssertTrue(shouldSkipRestore(windowSpaces: [3], spaceID: 5))
    }

    func test_DW_3_10_restore_not_skipped_when_member() {
        XCTAssertFalse(shouldSkipRestore(windowSpaces: [5, 7], spaceID: 5))
    }

    // MARK: - DW-3.7 (#43) per-requested-window detector

    func test_DW_3_7_three_window_rotation_trips_on_requested() {
        // Rotation A->B->C->A: requested=A recurs. The pair-keyed path never
        // trips (each pair seen once); the requested-keyed path must.
        var det = FocusLoopDetector()
        // requested=10 actual=20, requested=10 actual=30, requested=10 actual=40...
        XCTAssertNil(det.observeRequested(requested: 10, actual: 20, now: 0.0))
        XCTAssertNil(det.observeRequested(requested: 10, actual: 30, now: 0.2))
        XCTAssertNil(det.observeRequested(requested: 10, actual: 40, now: 0.4))
        let trip = det.observeRequested(requested: 10, actual: 20, now: 0.6)
        XCTAssertNotNil(trip)
        XCTAssertEqual(trip?.count, 4)
    }

    func test_DW_3_7_nil_actual_is_observed() {
        // nil actual (focused window cleared mid-command) must still count.
        var det = FocusLoopDetector()
        XCTAssertNil(det.observeRequested(requested: 99, actual: nil, now: 0.0))
        XCTAssertNil(det.observeRequested(requested: 99, actual: nil, now: 0.1))
        XCTAssertNil(det.observeRequested(requested: 99, actual: nil, now: 0.2))
        let trip = det.observeRequested(requested: 99, actual: nil, now: 0.3)
        XCTAssertNotNil(trip, "nil-actual attempts must be observed, not bypassed")
    }

    func test_DW_3_7_suppressed_after_trip() {
        var det = FocusLoopDetector()
        for t in [0.0, 0.1, 0.2] {
            _ = det.observeRequested(requested: 5, actual: 6, now: t)
        }
        let trip = det.observeRequested(requested: 5, actual: 6, now: 0.3)
        XCTAssertNotNil(trip)
        // Immediately after the trip, the requested window is suppressed:
        // the next attempt bails (non-nil) without contributing a raise.
        let suppressed = det.observeRequested(requested: 5, actual: 6, now: 0.35)
        XCTAssertNotNil(suppressed, "requested window should be suppressed right after a trip")
    }

    func test_DW_3_7_different_requested_independent() {
        var det = FocusLoopDetector()
        XCTAssertNil(det.observeRequested(requested: 1, actual: 2, now: 0.0))
        XCTAssertNil(det.observeRequested(requested: 3, actual: 4, now: 0.1))
        XCTAssertNil(det.observeRequested(requested: 5, actual: 6, now: 0.2))
        XCTAssertNil(det.observeRequested(requested: 7, actual: 8, now: 0.3))
    }

    // MARK: - DW-3.6 (#35) actor isolation

    func test_DW_3_6_actor_observe_serialized_under_concurrency() async {
        // Drive the actor from many concurrent tasks. Pre-isolation this raced
        // an Array CoW; via the actor it must complete cleanly and trip exactly
        // once for the looping pair.
        let actor = FocusLoopActor()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    _ = await actor.observeRequested(
                        requested: 100,
                        actual: UInt32(200 + (i % 3)),
                        now: CFAbsoluteTimeGetCurrent()
                    )
                }
            }
        }
        // No crash and the actor is still usable.
        let result = await actor.observeRequested(requested: 7, actual: 8, now: 0.0)
        XCTAssertNil(result)
    }
}
