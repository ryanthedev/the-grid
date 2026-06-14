import XCTest
@testable import GridServer

/// DW-7.14 (#58): the layout-cycle state wipe is deferred into applyLayoutBody.
/// computeCycleLayout/computePreviousLayout must NOT mutate state, so a throwing
/// apply can no longer leave the space wiped.
final class LayoutCycleDeferralTests: XCTestCase {

    // MARK: - compute is pure (no mutation)

    func test_DW_7_14_compute_cycle_does_not_mutate_state() async {
        let state = GridState(storage: InMemoryGridStorage())
        await state._test_setLayout(spaceID: "1", layoutID: "A")
        await state._test_setCells(spaceID: "1", cellIDs: ["left", "right"])
        await state._test_assignWindow(spaceID: "1", cellID: "left", windowID: 100)

        // Compute the next layout — must return "B" without touching cells.
        let next = await state.computeCycleLayout(spaceID: "1", availableLayouts: ["A", "B", "C"])
        XCTAssertEqual(next, "B")

        // Cells + assignment must be untouched (the wipe is deferred).
        let assignments = await state.getWindowAssignments(spaceID: "1")
        XCTAssertEqual(assignments["left"], [100], "computeCycleLayout must not wipe cells")
        let current = await state.getCurrentLayout(spaceID: "1")
        XCTAssertEqual(current, "A", "current layout unchanged until apply commits")
    }

    func test_DW_7_14_compute_previous_wraps_without_mutation() async {
        let state = GridState(storage: InMemoryGridStorage())
        await state._test_setLayout(spaceID: "1", layoutID: "A")
        // layoutIndex defaults to 0; previous wraps to last.
        let prev = await state.computePreviousLayout(spaceID: "1", availableLayouts: ["A", "B", "C"])
        XCTAssertEqual(prev, "C")
        let current = await state.getCurrentLayout(spaceID: "1")
        XCTAssertEqual(current, "A")
    }

    func test_DW_7_14_compute_empty_layouts_returns_current() async {
        let state = GridState(storage: InMemoryGridStorage())
        await state._test_setLayout(spaceID: "1", layoutID: "A")
        let cycled = await state.computeCycleLayout(spaceID: "1", availableLayouts: [])
        XCTAssertEqual(cycled, "A")
    }

    // MARK: - a throwing apply preserves prior state

    func test_DW_7_14_thrown_apply_preserves_prior_cells() async {
        // Reproduce the router sequence: compute (no wipe) → applyLayout (throws).
        let state = GridState(storage: InMemoryGridStorage())
        await state._test_setLayout(spaceID: "1", layoutID: "A")
        await state._test_setCells(spaceID: "1", cellIDs: ["left"])
        await state._test_assignWindow(spaceID: "1", cellID: "left", windowID: 100)

        let provider = MockStateProvider(state: WindowManagerState())
        let apply = GridApply()
        // _test_setup leaves gridConfig + gridFocus nil, so applyLayout throws
        // GridApplyError.noLayout at its guard — exactly the "apply throws" case.
        apply._test_setup(gridState: state, stateProvider: provider, windowController: MockWindowController())

        let target = await state.computeCycleLayout(spaceID: "1", availableLayouts: ["A", "B"])
        XCTAssertEqual(target, "B")

        do {
            try await apply.applyLayout(spaceID: "1", layoutID: target)
            XCTFail("apply should have thrown")
        } catch {
            // expected
        }

        // The crux of #58: the prior layout + cells survive a thrown apply.
        let current = await state.getCurrentLayout(spaceID: "1")
        XCTAssertEqual(current, "A", "thrown apply must not have switched the layout")
        let assignments = await state.getWindowAssignments(spaceID: "1")
        XCTAssertEqual(assignments["left"], [100],
                       "thrown apply must not have wiped the space's cells")
    }
}
