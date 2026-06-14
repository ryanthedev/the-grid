import XCTest
@testable import GridServer

// Phase 1 — Serialization foundation: CommandExecutor seam.
//
// DW-1.1 (#11,#3): serial executor — 4 overlapping submits complete in
//   submission order; inflight never exceeds 1 under a burst.
// DW-1.2 (#5): two concurrent `layout cycle` submits do not interleave —
//   a read-sleep-write body produces consistent final state.

// A fake command runner that records the order bodies START in and the peak
// number of bodies running concurrently. With a serial executor, bodies start
// in submission order and peak concurrency is 1.
private actor RecordingRunner: CommandRunning {
    private(set) var startOrder: [String] = []
    private(set) var finishOrder: [String] = []
    private(set) var inflight: Int = 0
    private(set) var maxInflight: Int = 0
    // Shared "layout id" written by `layout cycle` bodies to detect torn read/write.
    private(set) var layoutID: Int = 0
    private(set) var tornReadDetected = false

    func run(_ command: String) async -> CommandResult {
        inflight += 1
        maxInflight = max(maxInflight, inflight)
        startOrder.append(command)

        if command == "layout cycle" {
            // Read-compute-write across a suspension point. If two bodies
            // interleave here, the written value will not equal read+1.
            let read = layoutID
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
            if layoutID != read {
                tornReadDetected = true
            }
            layoutID = read + 1
        } else {
            // Force a suspension so an unserialized executor would interleave.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        finishOrder.append(command)
        inflight -= 1
        return .ok(command)
    }
}

final class CommandExecutorTests: XCTestCase {

    // MARK: - DW-1.1: ordering + inflight ≤ 1

    func test_DW_1_1_overlapping_submits_complete_in_submission_order() async {
        let runner = RecordingRunner()
        let executor = CommandExecutor(runner: runner)

        // Submit 4 commands "concurrently" — each in its own task, all racing.
        await withTaskGroup(of: Void.self) { group in
            for cmd in ["a", "b", "c", "d"] {
                group.addTask { _ = await executor.submit(cmd) }
                // Small stagger so submission order is well-defined a→b→c→d.
                try? await Task.sleep(nanoseconds: 200_000)
            }
        }

        let started = await runner.startOrder
        let finished = await runner.finishOrder
        XCTAssertEqual(started, ["a", "b", "c", "d"], "bodies start in submission order")
        XCTAssertEqual(finished, ["a", "b", "c", "d"], "bodies finish in submission order")
    }

    func test_DW_1_1_inflight_never_exceeds_one() async {
        let runner = RecordingRunner()
        let executor = CommandExecutor(runner: runner)

        // Held-key burst: 10 rapid submits.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { _ = await executor.submit("burst-\(i)") }
            }
        }

        let peak = await runner.maxInflight
        XCTAssertEqual(peak, 1, "at most one command body runs at a time")
    }

    // MARK: - DW-1.2: concurrent layout cycle serialized

    func test_DW_1_2_concurrent_layout_cycle_serialized() async {
        let runner = RecordingRunner()
        let executor = CommandExecutor(runner: runner)

        // Two rapid `layout cycle` presses.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await executor.submit("layout cycle") }
            group.addTask { _ = await executor.submit("layout cycle") }
        }

        let torn = await runner.tornReadDetected
        let finalID = await runner.layoutID
        XCTAssertFalse(torn, "no torn read between concurrent layout-cycle bodies")
        XCTAssertEqual(finalID, 2, "both applies committed consistently (1 then 2)")
    }
}
