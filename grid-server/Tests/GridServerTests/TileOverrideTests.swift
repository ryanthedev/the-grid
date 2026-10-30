import AppKit
import XCTest
@testable import GridServer

/// appRules `tile: true`: fixed-size apps without a fullscreen button
/// (iPhone Mirroring) tile instead of floating as picture-in-picture.
final class TileOverrideTests: XCTestCase {

    override func tearDown() {
        TileOverrides.set([])
        super.tearDown()
    }

    /// iPhone Mirroring's real shape: standard window, close/minimize/zoom, no fullscreen button.
    private func mirroringWindow(subrole: String = "AXStandardWindow", pid: pid_t = 0) -> WindowState {
        var w = WindowState(id: 4212)
        w.appName = "iPhone Mirroring"
        w.pid = pid
        w.role = "AXWindow"
        w.subrole = subrole
        w.hasCloseButton = true
        w.hasMinimizeButton = true
        w.hasZoomButton = true
        w.hasFullscreenButton = false
        w.frame = CGRect(x: 0, y: 0, width: 354, height: 781)
        return w
    }

    func test_without_rule_window_without_fullscreen_button_floats() {
        XCTAssertEqual(classifyWindow(window: mirroringWindow(), appName: "iPhone Mirroring"), .floating)
    }

    func test_tile_rule_by_app_name_makes_it_standard() {
        TileOverrides.set(["iPhone Mirroring"])
        XCTAssertEqual(classifyWindow(window: mirroringWindow(), appName: "iPhone Mirroring"), .standard)
    }

    func test_tile_rule_by_bundle_id_makes_it_standard() throws {
        // The test runner has no bundle ID; borrow any running app's pid.
        let app = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil },
            "no running app with a bundle ID")
        TileOverrides.set([app.bundleIdentifier!])
        let w = mirroringWindow(pid: app.processIdentifier)
        XCTAssertEqual(classifyWindow(window: w, appName: "iPhone Mirroring"), .standard)
    }

    func test_tile_rule_never_unfloats_a_dialog() {
        TileOverrides.set(["iPhone Mirroring"])
        let dialog = mirroringWindow(subrole: "AXDialog")
        XCTAssertEqual(classifyWindow(window: dialog, appName: "iPhone Mirroring"), .floating)
    }

    @MainActor
    func test_config_load_publishes_tile_rules() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grid-tile-test-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("thegrid")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try """
        appRules:
          - app: "iPhone Mirroring"
            tile: true
          - app: "Finder"
            float: true
        """.write(to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let oldHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let oldDirs = ProcessInfo.processInfo.environment["XDG_CONFIG_DIRS"]
        setenv("XDG_CONFIG_HOME", tmp.path, 1)
        // No system configs: point the search path at the empty temp root.
        setenv("XDG_CONFIG_DIRS", tmp.appendingPathComponent("none").path, 1)
        defer {
            if let oldHome { setenv("XDG_CONFIG_HOME", oldHome, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            if let oldDirs { setenv("XDG_CONFIG_DIRS", oldDirs, 1) } else { unsetenv("XDG_CONFIG_DIRS") }
        }

        let config = GridConfig()
        try await config.load()

        XCTAssertEqual(config.appRules.first { $0.app == "iPhone Mirroring" }?.tile, true)
        XCTAssertEqual(config.appRules.first { $0.app == "Finder" }?.tile, false)
        XCTAssertTrue(TileOverrides.matches(appName: "iPhone Mirroring", pid: 0))
        XCTAssertFalse(TileOverrides.matches(appName: "Finder", pid: 0))
    }
}
