import XCTest
@testable import GridServer

// Phase 2 pure-predicate unit tests. These exercise the decision logic off the
// AX/SkyLight boundary (code-standards testing pattern).
final class SpaceMigrationPolicyTests: XCTestCase {

    // MARK: - DW-2.1 (#2): reassignment gate

    func test_DW_2_1_classify_reassigned_when_old_absent() {
        // Old space 3 is gone from the refreshed OS set -> true reassignment.
        let routing = SpaceMigrationPolicy.classifySpaceChange(
            oldSpaceID: "3",
            newSpaceID: "414",
            refreshedSpaceIDs: ["414", "5", "6"]
        )
        XCTAssertEqual(routing, .reassigned)
    }

    func test_DW_2_1_classify_activated_when_old_present() {
        // Old space 3 still exists -> plain desktop switch, no migration.
        let routing = SpaceMigrationPolicy.classifySpaceChange(
            oldSpaceID: "3",
            newSpaceID: "7",
            refreshedSpaceIDs: ["3", "7", "9"]
        )
        XCTAssertEqual(routing, .activated)
    }

    func test_DW_2_1_classify_activated_on_noop() {
        let routing = SpaceMigrationPolicy.classifySpaceChange(
            oldSpaceID: "3",
            newSpaceID: "3",
            refreshedSpaceIDs: ["3"]
        )
        XCTAssertEqual(routing, .activated)
    }

    func test_DW_2_1_roundtrip_AB_A_both_classified_activated() {
        // Two persistent desktops A(3) and B(7) on one display. A->B and B->A
        // are both plain switches: the source ID is always still present, so
        // neither leg migrates and both spaces keep their layouts.
        let refreshed: Set<String> = ["3", "7"]
        let aToB = SpaceMigrationPolicy.classifySpaceChange(
            oldSpaceID: "3", newSpaceID: "7", refreshedSpaceIDs: refreshed)
        let bToA = SpaceMigrationPolicy.classifySpaceChange(
            oldSpaceID: "7", newSpaceID: "3", refreshedSpaceIDs: refreshed)
        XCTAssertEqual(aToB, .activated)
        XCTAssertEqual(bToA, .activated)
    }

    // MARK: - DW-2.2 (#6): numeric sort + destination guard

    func test_DW_2_2_numeric_sort_not_lexicographic() {
        // Lexicographic would give ["1001", "3", "999"]; numeric gives 3<999<1001.
        let sorted = SpaceMigrationPolicy.numericallySorted(["999", "1001", "3"])
        XCTAssertEqual(sorted, ["3", "999", "1001"])
    }

    func test_DW_2_2_numeric_sort_non_numeric_sorts_last_deterministically() {
        let sorted = SpaceMigrationPolicy.numericallySorted(["10", "abc", "2"])
        XCTAssertEqual(sorted, ["2", "10", "abc"])
    }

    func test_DW_2_2_canMigrate_blocks_significant_destination() {
        XCTAssertFalse(SpaceMigrationPolicy.canMigrate(
            sourceHasSignificantState: true,
            destinationHasSignificantState: true),
            "must refuse to overwrite a laid-out destination")
    }

    func test_DW_2_2_canMigrate_allows_empty_destination() {
        XCTAssertTrue(SpaceMigrationPolicy.canMigrate(
            sourceHasSignificantState: true,
            destinationHasSignificantState: false))
    }

    func test_DW_2_2_canMigrate_blocks_empty_source() {
        XCTAssertFalse(SpaceMigrationPolicy.canMigrate(
            sourceHasSignificantState: false,
            destinationHasSignificantState: false),
            "nothing to migrate from an empty source")
    }

    // MARK: - DW-2.4 (#51): re-resolve active-space confirmation

    func test_DW_2_4_confirm_returns_space_when_unchanged() {
        XCTAssertEqual(
            SpaceMigrationPolicy.confirmActiveSpace(expected: "100", current: "100"), "100")
    }

    func test_DW_2_4_confirm_aborts_when_space_switched() {
        // Resolved space 100 at entry; a switch made the active space 200.
        XCTAssertNil(
            SpaceMigrationPolicy.confirmActiveSpace(expected: "100", current: "200"),
            "a queued mutation must abort when the active space changed")
    }

    func test_DW_2_4_confirm_aborts_when_no_active_space() {
        XCTAssertNil(
            SpaceMigrationPolicy.confirmActiveSpace(expected: "100", current: nil))
    }

    // MARK: - DW-2.3 (#26): stale-write abort predicate

    func test_DW_2_3_abort_when_space_existed_then_vanished() {
        XCTAssertTrue(SpaceMigrationPolicy.shouldAbortStaleWrite(
            spaceExistedAtEntry: true, spaceStillExists: false),
            "a space that existed at apply entry but is gone now was migrated/closed away -- abort")
    }

    func test_DW_2_3_no_abort_when_space_still_exists() {
        XCTAssertFalse(SpaceMigrationPolicy.shouldAbortStaleWrite(
            spaceExistedAtEntry: true, spaceStillExists: true),
            "a surviving space is safe to write")
    }

    // Regression (the cascade this replaces): after a state reset the active
    // space has NO GridState entry until the first apply creates it, so
    // spaceStillExists is false at the write-phase check. The old `!spaceStillExists`
    // predicate aborted that first apply -> the space never got a layout ->
    // noLayout cascade (focus/move/borders all dead). A space that never existed
    // at entry MUST NOT abort: it is a legitimate first-time apply.
    func test_DW_2_3_no_abort_on_first_apply_space_never_existed() {
        XCTAssertFalse(SpaceMigrationPolicy.shouldAbortStaleWrite(
            spaceExistedAtEntry: false, spaceStillExists: false),
            "first-time apply (no entry at start, none yet) must be written, not aborted")
    }

    func test_DW_2_3_no_abort_when_space_created_during_apply() {
        XCTAssertFalse(SpaceMigrationPolicy.shouldAbortStaleWrite(
            spaceExistedAtEntry: false, spaceStillExists: true),
            "space created during the apply -- write it")
    }

    // MARK: - DW-2.6 (#24): zero/degenerate bounds guard

    func test_DW_2_6_isDegenerate_zero() {
        XCTAssertTrue(LayoutBoundsPolicy.isDegenerate(.zero))
    }

    func test_DW_2_6_isDegenerate_negative_dimension() {
        XCTAssertTrue(LayoutBoundsPolicy.isDegenerate(
            CGRect(x: 0, y: 0, width: -10, height: 100)))
        XCTAssertTrue(LayoutBoundsPolicy.isDegenerate(
            CGRect(x: 0, y: 0, width: 100, height: 0)))
    }

    func test_DW_2_6_isDegenerate_nonfinite() {
        XCTAssertTrue(LayoutBoundsPolicy.isDegenerate(
            CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)))
        XCTAssertTrue(LayoutBoundsPolicy.isDegenerate(
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)))
    }

    func test_DW_2_6_isDegenerate_valid_rect_is_false() {
        XCTAssertFalse(LayoutBoundsPolicy.isDegenerate(
            CGRect(x: 0, y: 25, width: 1920, height: 1055)))
    }

    // MARK: - DW-2.7 (#25): geometry-only diff

    func test_DW_2_7_changedDisplays_detects_frame_change() {
        let old: [String: DisplayGeometryPolicy.Geometry] = [
            "A": .init(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                       visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)),
        ]
        let new: [String: DisplayGeometryPolicy.Geometry] = [
            "A": .init(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                       visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 957)),
        ]
        XCTAssertEqual(DisplayGeometryPolicy.changedDisplays(old: old, new: new), ["A"])
    }

    func test_DW_2_7_changedDisplays_detects_visibleFrame_only_change() {
        // Same frame, Dock moved -> visibleFrame shrank.
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let old: [String: DisplayGeometryPolicy.Geometry] = [
            "A": .init(frame: frame, visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)),
        ]
        let new: [String: DisplayGeometryPolicy.Geometry] = [
            "A": .init(frame: frame, visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 990)),
        ]
        XCTAssertEqual(DisplayGeometryPolicy.changedDisplays(old: old, new: new), ["A"])
    }

    func test_DW_2_7_changedDisplays_empty_when_identical() {
        let geo = DisplayGeometryPolicy.Geometry(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055))
        let snap: [String: DisplayGeometryPolicy.Geometry] = ["A": geo, "B": geo]
        XCTAssertTrue(DisplayGeometryPolicy.changedDisplays(old: snap, new: snap).isEmpty)
    }

    func test_DW_2_7_changedDisplays_ignores_connect_disconnect() {
        // B only in new (connect), C only in old (disconnect): neither reported.
        let geo = DisplayGeometryPolicy.Geometry(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: nil)
        let old: [String: DisplayGeometryPolicy.Geometry] = ["A": geo, "C": geo]
        let new: [String: DisplayGeometryPolicy.Geometry] = ["A": geo, "B": geo]
        XCTAssertTrue(DisplayGeometryPolicy.changedDisplays(old: old, new: new).isEmpty)
    }
}
