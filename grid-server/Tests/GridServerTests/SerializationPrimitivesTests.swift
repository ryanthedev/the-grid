import XCTest
@testable import GridServer

// Phase 1 — Serialization foundation: pure-primitive unit tests.
//
// These exercise the four reusable primitives off the AX/SkyLight boundary:
//   RefcountedFence       — DW-1.3
//   GenerationCounter     — DW-1.7
//   SuppressedEventQueue  — DW-1.6
//   ActionTokenRegistry   — DW-1.4 (consume-once)
//   NudgeStepQueue        — DW-1.5 (coalesce + order)

final class SerializationPrimitivesTests: XCTestCase {

    // MARK: - DW-1.3: Refcounted fence

    // acquire×2 then release×1 — the window must remain fenced.
    func test_DW_1_3_fence_refcount_acquire_twice_release_once_still_fenced() {
        var fence = RefcountedFence(timeout: 5.0)
        let now = 1000.0
        fence.acquire(100, now: now)
        fence.acquire(100, now: now)
        let depth = fence.release(100)
        XCTAssertEqual(depth, 1, "one release of a doubly-acquired wid leaves refcount 1")
        XCTAssertTrue(fence.isFenced(100, now: now), "still fenced after one of two releases")
    }

    // Releasing down to zero removes the entry.
    func test_DW_1_3_release_to_zero_removes_entry() {
        var fence = RefcountedFence(timeout: 5.0)
        let now = 1000.0
        fence.acquire(100, now: now)
        fence.acquire(100, now: now)
        XCTAssertEqual(fence.release(100), 1)
        XCTAssertEqual(fence.release(100), 0, "second release drops to zero")
        XCTAssertFalse(fence.isFenced(100, now: now), "no longer fenced at refcount 0")
    }

    // Releasing a wid that was never acquired is a no-op (returns 0, no underflow).
    func test_DW_1_3_release_unheld_is_noop() {
        var fence = RefcountedFence(timeout: 5.0)
        let now = 1000.0
        XCTAssertEqual(fence.release(999), 0, "release of an unheld wid returns 0 (no-op)")
        XCTAssertFalse(fence.isFenced(999, now: now))
    }

    // A fence past its expiry is treated as not fenced.
    func test_DW_1_3_expiry_path_clears() {
        var fence = RefcountedFence(timeout: 5.0)
        fence.acquire(100, now: 1000.0)
        XCTAssertTrue(fence.isFenced(100, now: 1004.9), "still within timeout")
        XCTAssertFalse(fence.isFenced(100, now: 1005.1), "expired after timeout window")
    }

    // MARK: - DW-1.7: Monotonic generation counter

    func test_DW_1_7_generation_increments_per_action() {
        var gen = GenerationCounter()
        XCTAssertEqual(gen.current, 0)
        let g1 = gen.bump()
        let g2 = gen.bump()
        let g3 = gen.bump()
        XCTAssertEqual(g1, 1)
        XCTAssertEqual(g2, 2)
        XCTAssertEqual(g3, 3)
        XCTAssertEqual(gen.current, 3, "current reflects the latest generation")
    }

    func test_DW_1_7_generation_monotonic_under_interleave() {
        var gen = GenerationCounter()
        var last: UInt64 = gen.current
        for _ in 0..<1000 {
            let next = gen.bump()
            XCTAssertGreaterThan(next, last, "generation must strictly increase")
            last = next
        }
    }

    // MARK: - DW-1.6: Suppressed-event queue + replay

    // Events arriving while depth>0 are queued (not dropped) and drain FIFO at depth 0.
    func test_DW_1_6_events_queued_while_suppressed_replayed_in_order() {
        var queue = SuppressedEventQueue()
        // depth>0: enqueue rather than handle
        queue.enqueue(.windowCreated(wid: 10), generation: 1)
        queue.enqueue(.windowDestroyed(wid: 11), generation: 1)
        queue.enqueue(.windowCreated(wid: 12), generation: 2)
        XCTAssertEqual(queue.count, 3)

        let drained = queue.drain()
        XCTAssertEqual(drained.map { $0.event }, [
            .windowCreated(wid: 10),
            .windowDestroyed(wid: 11),
            .windowCreated(wid: 12),
        ], "replay preserves arrival order")
        XCTAssertEqual(drained.map { $0.generation }, [1, 1, 2],
            "each replayed event carries the generation it was queued under")
        XCTAssertEqual(queue.count, 0, "drain empties the queue")
    }

    // Replaying a create then destroy for the same wid is well-formed and idempotent
    // at the queue layer (the queue does not collapse them; handlers are idempotent).
    func test_DW_1_6_replay_of_gone_wid_is_idempotent() {
        var queue = SuppressedEventQueue()
        queue.enqueue(.windowDestroyed(wid: 50), generation: 1)
        queue.enqueue(.windowDestroyed(wid: 50), generation: 2)
        let drained = queue.drain()
        XCTAssertEqual(drained.count, 2, "duplicate destroys preserved; replay handler is idempotent")
        // Second drain is empty — replay consumes exactly once.
        XCTAssertTrue(queue.drain().isEmpty)
    }

    // MARK: - DW-1.4: Consume-once action token

    func test_DW_1_4_action_token_consumed_exactly_once() {
        var registry = ActionTokenRegistry()
        let token = registry.begin(label: "nudge")
        XCTAssertTrue(registry.isActive(token), "token active after begin")
        XCTAssertTrue(registry.consume(token), "first consume succeeds")
        XCTAssertFalse(registry.isActive(token), "token no longer active")
        XCTAssertFalse(registry.consume(token), "second consume of the same token is rejected")
    }

    // Two distinct begins yield distinct ids; consuming one does not affect the other.
    func test_DW_1_4_distinct_tokens_independent() {
        var registry = ActionTokenRegistry()
        let a = registry.begin(label: "nudge")
        let b = registry.begin(label: "nudge")
        XCTAssertNotEqual(a.id, b.id, "each begin gets a unique id")
        XCTAssertTrue(registry.consume(a))
        XCTAssertTrue(registry.isActive(b), "consuming a leaves b active")
        XCTAssertTrue(registry.consume(b))
    }

    // MARK: - DW-1.5: Nudge step coalescing + ordering

    // Same-direction repeats faster than the apply collapse but never back-step:
    // the queue carries the frame forward so N submits produce N ordered steps.
    func test_DW_1_5_coalesce_same_direction_repeats() {
        let q = NudgeStepQueue(step: 20)
        // start at origin x=100; three rights in a row
        var x: CGFloat = 100
        x = q.advance(current: x, direction: .right)
        XCTAssertEqual(x, 120)
        x = q.advance(current: x, direction: .right)
        XCTAssertEqual(x, 140)
        x = q.advance(current: x, direction: .right)
        XCTAssertEqual(x, 160, "three same-direction steps apply in order, none lost")
    }

    // A reversed direction steps back by exactly one — no overshoot from stale frames.
    func test_DW_1_5_reverse_direction_steps_back_once() {
        let q = NudgeStepQueue(step: 20)
        var x: CGFloat = 100
        x = q.advance(current: x, direction: .right) // 120
        x = q.advance(current: x, direction: .left)  // 100
        XCTAssertEqual(x, 100, "one right then one left returns to origin")
    }
}
