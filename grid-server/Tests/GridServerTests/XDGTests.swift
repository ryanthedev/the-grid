import XCTest
@testable import GridServer

final class XDGTests: XCTestCase {
    override func setUp() {
        super.setUp()
        unsetEnv("XDG_CONFIG_HOME")
        unsetEnv("XDG_CONFIG_DIRS")
        unsetEnv("XDG_STATE_HOME")
    }

    override func tearDown() {
        unsetEnv("XDG_CONFIG_HOME")
        unsetEnv("XDG_CONFIG_DIRS")
        unsetEnv("XDG_STATE_HOME")
        super.tearDown()
    }

    func testConfigHome_Default() {
        let got = XDG.configHome
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let want = "\(home)/.config"
        XCTAssertEqual(got, want)
    }

    func testConfigHome_Custom() {
        setenv("XDG_CONFIG_HOME", "/custom/config", 1)
        let got = XDG.configHome
        XCTAssertEqual(got, "/custom/config")
    }

    func testConfigDirs_Default() {
        let got = XDG.configDirs
        #if os(macOS)
        let want = ["/etc/xdg", "/opt/homebrew/etc", "/usr/local/etc"]
        #else
        let want = ["/etc/xdg"]
        #endif
        XCTAssertEqual(got, want)
    }

    func testConfigDirs_Custom() {
        setenv("XDG_CONFIG_DIRS", "/path1:/path2:/path3", 1)
        let got = XDG.configDirs
        let want = ["/path1", "/path2", "/path3"]
        XCTAssertEqual(got, want)
    }

    func testConfigDirs_FiltersRelativePaths() {
        setenv("XDG_CONFIG_DIRS", "/valid:relative/path::/another/valid:also/relative", 1)
        let got = XDG.configDirs
        let want = ["/valid", "/another/valid"]
        XCTAssertEqual(got, want)
    }

    func testStateHome_Default() {
        let got = XDG.stateHome
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let want = "\(home)/.local/state"
        XCTAssertEqual(got, want)
    }

    private func unsetEnv(_ name: String) {
        unsetenv(name)
    }
}
