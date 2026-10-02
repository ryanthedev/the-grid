import XCTest
@testable import GridServer

// Unplugging a display while awake pruned its spaces' grid state, and a
// re-dock never migrated old space IDs to new ones (that ran only on wake),
// so the display came back on the default layout (ska spaces 6/7; vana 5/6).
final class DisplayReconnectSpacesTests: XCTestCase {

    private func display(_ uuid: String, _ space: UInt64) -> DisplayState {
        var d = DisplayState(uuid: uuid, currentSpaceID: space, spaces: [space])
        d.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        d.visibleFrame = d.frame
        return d
    }

    func test_validator_keeps_an_unplugged_displays_spaces() async {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "7", layoutID: "two-col")
        await gridState._test_seedDisplaySpaces("ext", ["7"])

        var wmState = WindowManagerState()
        wmState.displays = [display("laptop", 1)]
        wmState.spaces["1"] = SpaceState(id: 1, uuid: "u1", type: "user", displayUUID: "laptop")

        let validator = StateValidator(gridState: gridState, stateProvider: MockStateProvider(state: wmState), connectionID: 0)
        await validator.validate(wmState: wmState)

        let layout = await gridState.getCurrentLayout(spaceID: "7")
        XCTAssertEqual(layout, "two-col", "parked space survives until its display returns")
    }

    func test_reconnect_migrates_the_displays_layout_to_its_new_space_id() async {
        let gridState = GridState()
        await gridState._test_setLayout(spaceID: "7", layoutID: "two-col")
        await gridState._test_seedDisplaySpaces("ext", ["7"])

        var wmState = WindowManagerState()
        wmState.displays = [display("laptop", 1), display("ext", 612)]
        wmState.spaces["1"] = SpaceState(id: 1, uuid: "u1", type: "user", displayUUID: "laptop")
        wmState.spaces["612"] = SpaceState(id: 612, uuid: "u612", type: "user", displayUUID: "ext")
        let mock = MockStateProvider(state: wmState)

        let reconciler = GridReconciler()
        reconciler._test_setup(stateProvider: mock, gridState: gridState)
        await reconciler._test_handle(.displayConnected(displayUUID: "ext"))

        let migrated = await gridState.getCurrentLayout(spaceID: "612")
        XCTAssertEqual(migrated, "two-col")
        let recorded = await gridState.getSpaceIDsForDisplay("ext")
        XCTAssertEqual(recorded, ["612"])
        withExtendedLifetime(mock) {}
    }
}
