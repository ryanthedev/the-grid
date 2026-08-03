//
// SpaceDerivationPolicyTests.swift
// GridServerTests
//
// Covers every rule in SpaceDerivationPolicy, plus the two regressions that
// pull in opposite directions:
//
//  - the parked-window bug (this change): a window off-screen on an inactive
//    space of its own display must keep that space, not get re-pinned to
//    whatever is current.
//  - the 0b7edd6 virtual-display fix: a window whose reported space belongs to
//    no space on its geometric display must still be overridden by geometry.
//
// Pre-change behavior, for the record — the old code at StateManager.swift
// (deriveSpaceFromDisplay, before extraction) ran an unconditional
// `window.spaces = [display.currentSpaceID]` whenever the geometric display
// had a nonzero current space, so testParkedWindowKeepsItsSpace's input
// (originalSpaces [4], display spaces [3,4] current 3) yielded [3]. There is no
// red-green claim here: the policy type does not exist on the parent commit, so
// a test naming it would fail to compile rather than fail.
//

import XCTest
@testable import GridServer

final class SpaceDerivationPolicyTests: XCTestCase {

    // Display with two spaces, currently showing 3.
    private func twoSpaceDisplay(uuid: String = "DISPLAY-A", current: UInt64 = 3) -> DisplayState {
        var d = DisplayState(uuid: uuid, currentSpaceID: current, spaces: [3, 4])
        d.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return d
    }

    // MARK: - Rule 1: no usable display

    func testNoDisplayKeepsReportedSpaces() {
        let result = SpaceDerivationPolicy.derive(
            displayUUID: nil,
            originalSpaces: [7],
            isOnScreen: true,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [7])
        XCTAssertEqual(result.source, .reported)
        XCTAssertNil(result.warning)
    }

    func testNoDisplayAndNothingReportedWarnsBothFailed() {
        let result = SpaceDerivationPolicy.derive(
            displayUUID: nil,
            originalSpaces: [],
            isOnScreen: true,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [])
        XCTAssertEqual(result.warning, .bothFailed)
    }

    func testZeroCurrentSpaceIsNotUsable() {
        let display = DisplayState(uuid: "DISPLAY-A", currentSpaceID: 0, spaces: [3, 4])
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [4],
            isOnScreen: false,
            displays: [display]
        )
        XCTAssertEqual(result.spaces, [4])
        XCTAssertEqual(result.source, .reported)
    }

    // MARK: - Rule 2: nothing reported

    func testEmptyReportedFallsBackToGeometry() {
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [],
            isOnScreen: false,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [3])
        XCTAssertEqual(result.source, .geometric)
        XCTAssertNil(result.warning)
    }

    // MARK: - Rule 3: membership unknown

    func testUnknownDisplayMembershipFallsBackToGeometryAndWarns() {
        let display = DisplayState(uuid: "DISPLAY-A", currentSpaceID: 3, spaces: [])
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [4],
            isOnScreen: false,
            displays: [display]
        )
        // Preserves historical behavior — but says so, so a stale membership
        // list cannot turn this policy into a silent no-op.
        XCTAssertEqual(result.spaces, [3])
        XCTAssertEqual(result.source, .geometric)
        XCTAssertEqual(result.warning, .membershipUnknown(displayUUID: "DISPLAY-A"))
    }

    // MARK: - Rule 4: on-screen beats the SkyLight lag

    func testOnScreenWindowTakesCurrentSpaceDespiteStaleReport() {
        // The Mission-Control edge-drag case: the window moved to space 4 on
        // the same display, SkyLight still says 3. It is visible, so it is on
        // the display's current space by definition.
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [3],
            isOnScreen: true,
            displays: [twoSpaceDisplay(current: 4)]
        )
        XCTAssertEqual(result.spaces, [4])
        XCTAssertEqual(result.source, .geometric)
        XCTAssertEqual(result.warning, .override(from: [3], to: 4))
    }

    func testOnScreenWindowAlreadyAgreeingDoesNotWarn() {
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [3],
            isOnScreen: true,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [3])
        XCTAssertEqual(result.source, .geometric, "must come from rule 4, not rule 5")
        XCTAssertNil(result.warning)
    }

    func testOnScreenAndOffScreenDivergeOnTheSameInput() {
        // Guards the rule 4 / rule 5 split itself: same reported space, same
        // display, opposite visibility, opposite answers. If rule 4 were
        // deleted both would fall through to rule 5 and this would fail.
        let display = twoSpaceDisplay(current: 3)
        let visible = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A", originalSpaces: [4],
            isOnScreen: true, displays: [display]
        )
        let parked = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A", originalSpaces: [4],
            isOnScreen: false, displays: [display]
        )
        XCTAssertEqual(visible.spaces, [3], "a visible window is on the current space")
        XCTAssertEqual(parked.spaces, [4], "a parked window keeps its own space")
    }

    // MARK: - Rule 1 post-condition

    func testNoDisplayNarrowsAMultiElementReportToOne() {
        let result = SpaceDerivationPolicy.derive(
            displayUUID: nil,
            originalSpaces: [9, 7],
            isOnScreen: false,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [7])
    }

    // MARK: - Rule 5: the parked-window regression (this change)

    func testParkedWindowKeepsItsSpace() {
        // The bug. Window is off-screen on space 4; display currently shows 3.
        // Old behavior re-pinned it to [3] on every poll tick, which is how a
        // window drifted out of its cell and another appeared there.
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [4],
            isOnScreen: false,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [4])
        XCTAssertEqual(result.source, .reported)
        XCTAssertNil(result.warning)
    }

    func testParkedWindowResultIsNarrowedToOneSpace() {
        // A mixed list must not propagate: everything downstream (grid
        // membership, pickBestSpace, activeSpaceID) assumes one space.
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [3, 4],
            isOnScreen: false,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [3], "current space wins when it is in the intersection")
        XCTAssertEqual(result.source, .reported)
    }

    func testParkedWindowWithoutCurrentSpacePicksDeterministically() {
        var display = twoSpaceDisplay(current: 9)
        display.spaces = [4, 5, 9]
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [5, 4],
            isOnScreen: false,
            displays: [display]
        )
        XCTAssertEqual(result.spaces, [4], "lowest on-display space when current is not reported")
    }

    // MARK: - Rule 6: the 0b7edd6 virtual-display regression

    func testReportedSpaceOnNoKnownDisplayIsOverriddenByGeometry() {
        // The 0b7edd6 case: Spotify reported space 64, geometrically on the
        // space-41 display. 64 belongs to no space of that display.
        var display = DisplayState(uuid: "VIRTUAL", currentSpaceID: 41, spaces: [41])
        display.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "VIRTUAL",
            originalSpaces: [64],
            isOnScreen: false,
            displays: [display]
        )
        XCTAssertEqual(result.spaces, [41])
        XCTAssertEqual(result.source, .geometric)
        XCTAssertEqual(result.warning, .override(from: [64], to: 41))
    }

    func testMixedListWithOffDisplaySpaceDoesNotLeakTheBogusEntry() {
        // [3, 64] — 3 is real on this display, 64 is the 0b7edd6 misreport.
        // Trusting the list wholesale would propagate 64.
        let result = SpaceDerivationPolicy.derive(
            displayUUID: "DISPLAY-A",
            originalSpaces: [3, 64],
            isOnScreen: false,
            displays: [twoSpaceDisplay()]
        )
        XCTAssertEqual(result.spaces, [3])
        XCTAssertFalse(result.spaces.contains(64))
    }

    // MARK: - Post-condition

    func testResultIsAlwaysAtMostOneSpace() {
        let display = twoSpaceDisplay()
        for original in [[], [3], [4], [3, 4], [64], [3, 64], [4, 64]] as [[UInt64]] {
            for onScreen in [true, false] {
                // nil covers rule 1, which callers now reach with raw
                // SkyLight lists rather than an already-narrowed value.
                for uuid in ["DISPLAY-A", "UNKNOWN", nil] {
                let result = SpaceDerivationPolicy.derive(
                    displayUUID: uuid,
                    originalSpaces: original,
                    isOnScreen: onScreen,
                    displays: [display]
                )
                XCTAssertLessThanOrEqual(
                    result.spaces.count, 1,
                    "original=\(original) onScreen=\(onScreen) uuid=\(uuid ?? "nil") "
                        + "produced \(result.spaces)"
                )
                }
            }
        }
    }
}
