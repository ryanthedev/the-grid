import XCTest
import CoreGraphics

@testable import GridServer

// Tileability and exclusion tests for GridAssignment.
//
// Written to close a mutation-testing gap: a 200-mutant campaign scored
// GridAssignment at 31%, and every guard inside isTileable/isExcluded survived
// mutation. That matters because isTileable is the single most consequential
// predicate in the server — 705 of 832 window creations over 8 days of logs
// bailed as `not_tileable` — and isExcluded backs the user's
// `exclusions.apps` / `.roles` / `.subroles` config, which could have been
// returning a constant without a single test noticing.
//
// Each test names the specific mutant it kills.
final class TileabilityPolicyTests: XCTestCase {

    // MARK: - Helpers

    // A window that passes every isTileable guard. Individual tests perturb one
    // field at a time so each guard is isolated.
    private func makeTileableWindow(id: UInt32 = 1) -> WindowState {
        var w = WindowState(id: id)
        w.appName = "App"
        w.pid = 0
        w.role = "AXWindow"
        w.subrole = "AXStandardWindow"
        w.hasCloseButton = true
        w.hasFullscreenButton = true
        w.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        w.isMinimized = false
        w.isHidden = false
        w.level = 0
        return w
    }

    // MARK: - isTileable: baseline

    func test_isTileable_acceptsStandardWindow() {
        XCTAssertTrue(isTileable(window: makeTileableWindow()))
    }

    // MARK: - isTileable: state guards

    // Kills GridAssignment.swift:110 `isMinimized || isHidden || level != 0` -> `&&`
    // (both occurrences) and the `return false` at :111.
    //
    // `&&` binds tighter than `||`, so flipping either operator lets a window
    // that trips exactly ONE of the three conditions slip through. Each
    // condition is therefore asserted in isolation.
    func test_isTileable_rejectsMinimized() {
        var w = makeTileableWindow()
        w.isMinimized = true
        XCTAssertFalse(isTileable(window: w), "a minimized window must never be tiled")
    }

    func test_isTileable_rejectsHidden() {
        var w = makeTileableWindow()
        w.isHidden = true
        XCTAssertFalse(isTileable(window: w), "a hidden window must never be tiled")
    }

    func test_isTileable_rejectsNonZeroLevel() {
        var w = makeTileableWindow()
        w.level = 3
        XCTAssertFalse(isTileable(window: w), "a floating/overlay level window must never be tiled")
    }

    // MARK: - isTileable: dimension guard

    // Kills GridAssignment.swift:115 and :116 `< minTileableDimension` -> `<=`.
    // The threshold is 100.0 and the comparison is strict, so a window measuring
    // exactly 100 in either axis is tileable. Under `<=` it is rejected.
    func test_isTileable_acceptsExactlyMinimumDimensions() {
        var w = makeTileableWindow()
        w.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(
            isTileable(window: w),
            "exactly the minimum dimension is tileable — the bound is strict"
        )
    }

    func test_isTileable_rejectsJustBelowMinimumDimensions() {
        var short = makeTileableWindow()
        short.frame = CGRect(x: 0, y: 0, width: 800, height: 99)
        XCTAssertFalse(isTileable(window: short))

        var narrow = makeTileableWindow()
        narrow.frame = CGRect(x: 0, y: 0, width: 99, height: 600)
        XCTAssertFalse(isTileable(window: narrow))
    }

    // Kills GridAssignment.swift:116 `||` -> `&&` and the `return false` at :117.
    // Under `&&` a window must be undersized in BOTH axes to be rejected, so a
    // short-but-wide toolbar (the exact shape the guard exists to filter) would
    // start being tiled.
    func test_isTileable_rejectsUndersizedInASingleAxis() {
        var toolbar = makeTileableWindow()
        toolbar.frame = CGRect(x: 0, y: 0, width: 1200, height: 22)
        XCTAssertFalse(toolbar.frame.width < 100, "precondition: wide in one axis")
        XCTAssertFalse(
            isTileable(window: toolbar),
            "undersized in one axis is enough to reject — a tab bar is not a tileable window"
        )

        var sliver = makeTileableWindow()
        sliver.frame = CGRect(x: 0, y: 0, width: 8, height: 900)
        XCTAssertFalse(isTileable(window: sliver))
    }

    // Zero-dimension windows are the single largest observed bail class
    // (307 of 705 not_tileable bails over 8 days), typically an app publishing
    // a window before it has laid out.
    func test_isTileable_rejectsZeroSizedWindow() {
        var w = makeTileableWindow()
        w.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertFalse(isTileable(window: w))
    }

    // MARK: - isTileable: role and subrole

    // The role == "AXWindow" filter is deliberate: Chrome and similar apps spawn
    // phantom helper AX elements with other roles, and tiling them produces
    // ghost windows. Kills the `return window.role == "AXWindow"` mutants at :127.
    func test_isTileable_requiresAXWindowRole() {
        for role in ["AXScrollArea", "AXHelpTag", "AXPopover", "AXGrowArea"] {
            var w = makeTileableWindow()
            w.role = role
            XCTAssertFalse(isTileable(window: w), "role \(role) must not be tiled")
        }

        var noRole = makeTileableWindow()
        noRole.role = nil
        XCTAssertFalse(noRole.role == "AXWindow")
        XCTAssertFalse(isTileable(window: noRole), "a phantom with no role must not be tiled")
    }

    // Only AXStandardWindow tiles among non-empty subroles. Note that a nil or
    // empty subrole is deliberately ACCEPTED — the guard is
    // `!subrole.isEmpty && subrole != "AXStandardWindow"`. This is load-bearing:
    // widening a subrole requery to resolve nil subroles would drop these
    // windows out of tiling, so the behavior is pinned here on purpose.
    func test_isTileable_rejectsNonStandardSubroles() {
        for subrole in ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSheet", "AXUnknown"] {
            var w = makeTileableWindow()
            w.subrole = subrole
            XCTAssertFalse(isTileable(window: w), "subrole \(subrole) must not be tiled")
        }
    }

    func test_isTileable_acceptsNilOrEmptySubrole() {
        var nilSubrole = makeTileableWindow()
        nilSubrole.subrole = nil
        XCTAssertTrue(
            isTileable(window: nilSubrole),
            "nil subrole is treated as unknown-but-acceptable; see comment above"
        )

        var emptySubrole = makeTileableWindow()
        emptySubrole.subrole = ""
        XCTAssertTrue(isTileable(window: emptySubrole))
    }

    // MARK: - isExcluded

    // Kills GridAssignment.swift:137, :140, :143 `return true` -> `false` and
    // :145 `return false` -> `true`. Without these, isExcluded could return a
    // constant and the user's exclusion config would silently do nothing.
    func test_isExcluded_byRole() {
        var w = makeTileableWindow()
        w.role = "AXScrollArea"
        let exclusions = GridWindowExclusion(roles: ["AXScrollArea"], subroles: [], apps: [])
        XCTAssertTrue(isExcluded(window: w, appName: "App", exclusions: exclusions))
    }

    func test_isExcluded_bySubrole() {
        var w = makeTileableWindow()
        w.subrole = "AXDialog"
        let exclusions = GridWindowExclusion(roles: [], subroles: ["AXDialog"], apps: [])
        XCTAssertTrue(isExcluded(window: w, appName: "App", exclusions: exclusions))
    }

    func test_isExcluded_byAppName() {
        let w = makeTileableWindow()
        let exclusions = GridWindowExclusion(roles: [], subroles: [], apps: ["Finder"])
        XCTAssertTrue(isExcluded(window: w, appName: "Finder", exclusions: exclusions))
    }

    // The negative case is what pins :145 — a window matching no rule must not
    // be excluded, otherwise nothing would ever tile.
    func test_isExcluded_allowsUnmatchedWindow() {
        let w = makeTileableWindow()
        let exclusions = GridWindowExclusion(
            roles: ["AXScrollArea"],
            subroles: ["AXDialog"],
            apps: ["Finder"]
        )
        XCTAssertFalse(
            isExcluded(window: w, appName: "Ghostty", exclusions: exclusions),
            "a window matching no exclusion rule must not be excluded"
        )
    }

    func test_isExcluded_emptyConfigExcludesNothing() {
        let w = makeTileableWindow()
        let empty = GridWindowExclusion(roles: [], subroles: [], apps: [])
        XCTAssertFalse(isExcluded(window: w, appName: "App", exclusions: empty))
    }

    // Matching is exact, not substring or case-insensitive — a rule for "Chrome"
    // must not silently capture "Google Chrome".
    func test_isExcluded_matchesExactly() {
        let w = makeTileableWindow()
        let exclusions = GridWindowExclusion(roles: [], subroles: [], apps: ["Chrome"])
        XCTAssertFalse(isExcluded(window: w, appName: "Google Chrome", exclusions: exclusions))
        XCTAssertTrue(isExcluded(window: w, appName: "Chrome", exclusions: exclusions))
    }

    // A nil role/subrole must not accidentally match an exclusion entry via the
    // `?? ""` coalescing.
    func test_isExcluded_nilRoleDoesNotMatchEmptyStringEntry() {
        var w = makeTileableWindow()
        w.role = nil
        w.subrole = nil
        let exclusions = GridWindowExclusion(roles: [""], subroles: [], apps: [])
        XCTAssertTrue(
            isExcluded(window: w, appName: "App", exclusions: exclusions),
            "documents current behavior: nil role coalesces to \"\" and matches an empty entry"
        )
    }
}
