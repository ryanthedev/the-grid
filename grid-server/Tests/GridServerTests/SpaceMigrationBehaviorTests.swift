import XCTest
@testable import GridServer

// Phase 2 behavioral / integration tests: drive GridState, GridReconciler and
// GridApply through real wiring with the existing fakes (MockStateProvider,
// MockBorderRenderer, StubGridApply, InMemoryGridStorage).
final class SpaceMigrationBehaviorTests: XCTestCase {

    // Records validate/resume calls without doing real AX work.
    private func makeValidator(_ gridState: GridState) -> StateValidator {
        StateValidator(gridState: gridState, stateProvider: StateManager.shared, connectionID: 0)
    }

    // MARK: - DW-2.2 (#6): migrateSpaceIDs destination guard + numeric pairing

    func test_DW_2_2_migrateSpaceIDs_refuses_to_overwrite_significant_destination() async {
        let gridState = GridState()
        // Source space 3 has a layout; destination 414 ALSO has a layout.
        await gridState._test_setLayout(spaceID: "3", layoutID: "src-layout")
        await gridState._test_setLayout(spaceID: "414", layoutID: "dst-layout")
        // Old snapshot for the display: [3]; new OS list: [414].
        await gridState._test_seedDisplaySpaces("display-1", ["3"])

        let migrated = await gridState.migrateSpaceIDs(
            currentDisplaySpaces: ["display-1": ["414"]])

        XCTAssertFalse(migrated, "must refuse overwriting a laid-out destination")
        // Destination keeps its OWN layout; source is NOT wiped.
        let dst = await gridState.getCurrentLayout(spaceID: "414")
        let src = await gridState.getCurrentLayout(spaceID: "3")
        XCTAssertEqual(dst, "dst-layout", "destination layout must be preserved")
        XCTAssertEqual(src, "src-layout", "source must remain untouched when migration refused")
    }

    func test_DW_2_2_migrateSpaceIDs_migrates_into_empty_destination() async {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "3", layoutID: "src-layout")
        await gridState._test_seedDisplaySpaces("display-1", ["3"])

        let migrated = await gridState.migrateSpaceIDs(
            currentDisplaySpaces: ["display-1": ["414"]])

        XCTAssertTrue(migrated)
        let dst = await gridState.getCurrentLayout(spaceID: "414")
        let src = await gridState.getCurrentLayout(spaceID: "3")
        XCTAssertEqual(dst, "src-layout", "state migrated to new ID")
        XCTAssertEqual(src, "", "old ID removed")
    }

    func test_DW_2_2_migrateSpaceIDs_numeric_pairing_not_lexicographic() async {
        let gridState = GridState()
        // Two spaces on one display. Layouts let us tell them apart.
        await gridState._test_setLayout(spaceID: "3", layoutID: "layout-3")
        await gridState._test_setLayout(spaceID: "1001", layoutID: "layout-1001")
        // Old snapshot numeric order: [3, 1001].
        await gridState._test_seedDisplaySpaces("display-1", ["3", "1001"])

        // New OS list, numeric order: [5, 999]. Positional numeric pairing:
        // 3 -> 5, 1001 -> 999. Lexicographic would have paired 1001 -> 5.
        let migrated = await gridState.migrateSpaceIDs(
            currentDisplaySpaces: ["display-1": ["999", "5"]])

        XCTAssertTrue(migrated)
        let layoutAt5 = await gridState.getCurrentLayout(spaceID: "5")
        let layoutAt999 = await gridState.getCurrentLayout(spaceID: "999")
        XCTAssertEqual(layoutAt5, "layout-3",
            "smallest old (3) must pair with smallest new (5)")
        XCTAssertEqual(layoutAt999, "layout-1001",
            "largest old (1001) must pair with largest new (999)")
    }

    func test_DW_2_2_migrateSpace_live_refuses_significant_destination() async {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "3", layoutID: "src")
        await gridState._test_setLayout(spaceID: "7", layoutID: "dst")

        let migrated = await gridState.migrateSpace(from: "3", to: "7")
        XCTAssertTrue(migrated.isEmpty, "live migrate must not clobber a laid-out destination")
        let dst = await gridState.getCurrentLayout(spaceID: "7")
        let src = await gridState.getCurrentLayout(spaceID: "3")
        XCTAssertEqual(dst, "dst")
        XCTAssertEqual(src, "src")
    }

    // MARK: - DW-2.5 (#23): wake validator resume gated on lock state

    func test_DW_2_5_wake_while_locked_defers_validator_resume() async throws {
        let gridState = GridState()
        let reconciler = GridReconciler()
        reconciler.setup(
            gridState: gridState,
            gridConfig: GridConfig(),
            stateProvider: StateManager.shared,
            borderRenderer: SimpleBorderManager(connectionID: 0)
        )
        let validator = makeValidator(gridState)
        reconciler.setValidator(validator)
        let stubApply = StubGridApply()
        reconciler.setApply(stubApply)

        // Lock the screen (pauses validator), then wake while still locked.
        await reconciler._test_handle(.screenLocked)
        let pausedAfterLock = await validator._test_isPaused()
        XCTAssertTrue(pausedAfterLock, "precondition: lock pauses validator")

        await reconciler._test_handle(.systemWoke)

        let stillPaused = await validator._test_isPaused()
        XCTAssertTrue(stillPaused,
            "wake while locked must NOT resume the validator (DW-2.5)")
    }

    func test_DW_2_5_wake_while_unlocked_resumes_validator() async throws {
        let gridState = GridState()
        let reconciler = GridReconciler()
        reconciler.setup(
            gridState: gridState,
            gridConfig: GridConfig(),
            stateProvider: StateManager.shared,
            borderRenderer: SimpleBorderManager(connectionID: 0)
        )
        let validator = makeValidator(gridState)
        reconciler.setValidator(validator)
        reconciler.setApply(StubGridApply())

        // Simulate: locked then unlocked (e.g. clamshell sleep, user unlocked),
        // then a wake event arrives.
        await reconciler._test_handle(.screenLocked)
        await reconciler._test_handle(.screenUnlocked)
        await reconciler._test_handle(.systemWoke)

        let paused = await validator._test_isPaused()
        XCTAssertFalse(paused, "wake while unlocked must resume the validator")
    }

    // MARK: - DW-2.6 (#24): applyLayout skips zero/degenerate bounds

    func test_DW_2_6_applyLayout_zero_bounds_skips_with_noDisplayBounds() async {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "100", layoutID: "single-tabbed")

        // Build a wmState whose display has NIL frame/visibleFrame -> the
        // computed display bounds resolve to .zero (the wake/dock-replug
        // degenerate state). A tileable window exists on the space so the
        // apply would otherwise proceed.
        var wmState = WindowManagerState()
        var display = DisplayState(uuid: "display-1", currentSpaceID: 100, spaces: [100])
        display.frame = nil
        display.visibleFrame = nil
        wmState.displays = [display]
        wmState.spaces["100"] = SpaceState(
            id: 100, uuid: "su", type: "user", displayUUID: "display-1")
        var window = WindowState(id: 7)
        window.pid = 1
        window.role = "AXWindow"
        window.subrole = "AXStandardWindow"
        window.hasCloseButton = true
        window.hasFullscreenButton = true
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.spaces = [100]
        wmState.windows["7"] = window
        wmState.metadata.activeSpaceID = 100

        let provider = MockStateProvider(state: wmState)
        let gridConfig = GridConfig()
        let windowController = MockWindowController()
        let border = SimpleBorderManager(connectionID: 0)
        let reconciler = GridReconciler()
        let gridFocus = GridFocus()
        gridFocus.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateProvider: provider,
            windowController: windowController
        )
        let apply = GridApply()
        apply.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateProvider: provider,
            windowController: windowController,
            gridReconciler: reconciler,
            simpleBorderManager: border,
            gridFocus: gridFocus
        )

        do {
            try await apply.applyLayout(spaceID: "100", layoutID: "single-tabbed")
            XCTFail("applyLayout must throw noDisplayBounds on zero/degenerate bounds")
        } catch GridApplyError.noDisplayBounds {
            // expected: skip + err.layout.zero_bounds logged
        } catch {
            XCTFail("expected noDisplayBounds, got \(error)")
        }

        // The window must NOT have been placed against zero bounds.
        let placedAny = windowController.calls.contains { call in
            if case .setWindowFrame = call { return true }
            return false
        }
        XCTAssertFalse(placedAny, "no AX placement against degenerate bounds (DW-2.6)")
    }

    // MARK: - DW-2.8 (#52): display-disconnect prunes via GridState's own map

    func test_DW_2_8_disconnect_prunes_assignments_via_gridstate_displayspaces() async {
        let gridState = GridState()
        // Space 50 on display-ext has a tiled window. wmState no longer lists
        // the display (it is gone), but GridState remembers its spaces.
        await gridState._test_setLayout(spaceID: "50", layoutID: "grid")
        await gridState._test_assignWindow(spaceID: "50", cellID: "A", windowID: 900)
        await gridState._test_seedDisplaySpaces("display-ext", ["50"])

        let reconciler = GridReconciler()
        // wmState has NO display-ext space (already disconnected at SLS level).
        let provider = MockStateProvider(state: WindowManagerState())
        reconciler._test_setup(
            stateProvider: provider,
            gridState: gridState,
            borderRenderer: MockBorderRenderer()
        )

        await reconciler._test_handle(.displayDisconnected(displayUUID: "display-ext"))

        let assignments = await gridState.getWindowAssignments(spaceID: "50")
        let remaining = assignments.values.flatMap { $0 }
        XCTAssertFalse(remaining.contains(900),
            "window on the disconnected display's space must be pruned (DW-2.8/#52)")
    }

    // MARK: - DW-2.7/DW-2.9 (#25): geometry-change event reapplies layouts (debounced)

    func test_DW_2_7_displayGeometryChanged_reapplies_after_debounce() async throws {
        let gridState = GridState()
        let gridConfig = GridConfig()
        let reconciler = GridReconciler()
        reconciler.setup(
            gridState: gridState,
            gridConfig: gridConfig,
            stateProvider: StateManager.shared,
            borderRenderer: SimpleBorderManager(connectionID: 0)
        )
        let stubApply = StubGridApply()
        reconciler.setApply(stubApply)

        // Drive the geometry-change event (the new case exists -> DW-2.9 type
        // coverage). The handler debounces ~300ms before reapplying.
        await reconciler._test_handle(.displayGeometryChanged(displayUUID: "display-1"))

        // Before the debounce elapses, no reapply yet.
        XCTAssertEqual(stubApply.callCount, 0, "reapply must be debounced, not immediate")

        // Wait past the debounce window.
        try await Task.sleep(for: .milliseconds(450))

        XCTAssertEqual(stubApply.callCount, 1,
            "geometry change reapplies layouts once after the debounce (DW-2.7)")
    }

    // MARK: - DW-2.8 (#20): spaceActivated resyncs borders

    func test_DW_2_8_spaceActivated_syncs_borders_for_active_space() async {
        // A space with no committed layout still takes the border-sync path
        // (clearing via empty assignments). Reaching setCellAssignments for the
        // activated display is the proof that the dead handleSpaceChanged path
        // is replaced (#20) — the switch now drives a real border resync.
        let gridState = GridState()

        let border = MockBorderRenderer()
        // GridConfig is held weakly by the reconciler; retain it in the test.
        let gridConfig = GridConfig()
        let reconciler = GridReconciler()
        reconciler._test_setup(
            stateProvider: MockStateProvider(state: WindowManagerState()),
            gridState: gridState,
            gridConfig: gridConfig,
            borderRenderer: border
        )

        await reconciler._test_handle(.spaceActivated(spaceID: "77", displayUUID: "display-1"))

        let synced = border.calls.contains { call in
            if case .setCellAssignments(_, let display, _, _) = call {
                return display == "display-1"
            }
            return false
        }
        XCTAssertTrue(synced, "spaceActivated must resync borders for the active space (DW-2.8/#20)")
    }
}
