//
// ChromeInstancePolicyTests.swift
// GridServerTests
//
// Phase 2: distinguish separate --user-data-dir Chrome instances.
// Covers the pure argv extractor + basename label mapping (DW-2.1, DW-2.3),
// the per-PID KERN_PROCARGS2 reader's failure/cache behavior (DW-2.2), and the
// ChromeEnricher subtitle/stable-id composition (DW-2.3, DW-2.4).
//

import XCTest
@testable import GridServer

final class ChromeInstancePolicyTests: XCTestCase {

    // MARK: - DW-2.1: argv extraction

    // DW-2.1: "--user-data-dir=/path" form.
    func test_DW_2_1_extracts_equals_form() {
        let argv = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--user-data-dir=/tmp/chrome-cdp-profile",
            "--remote-debugging-port=9222",
        ]
        XCTAssertEqual(
            ChromeInstancePolicy.extractUserDataDir(argv: argv),
            "/tmp/chrome-cdp-profile"
        )
    }

    // DW-2.1: "--user-data-dir /path" (separate token) form.
    func test_DW_2_1_extracts_space_form() {
        let argv = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--user-data-dir",
            "/tmp/chrome-cdp-profile",
        ]
        XCTAssertEqual(
            ChromeInstancePolicy.extractUserDataDir(argv: argv),
            "/tmp/chrome-cdp-profile"
        )
    }

    // DW-2.1: absent flag -> nil. Also covers a dangling "--user-data-dir" with
    // no following value (defensive: nil, not a crash).
    func test_DW_2_1_nil_when_absent() {
        XCTAssertNil(
            ChromeInstancePolicy.extractUserDataDir(
                argv: ["/path/to/Chrome", "--remote-debugging-port=9222"]
            )
        )
        XCTAssertNil(ChromeInstancePolicy.extractUserDataDir(argv: []))
        XCTAssertNil(
            ChromeInstancePolicy.extractUserDataDir(argv: ["/path/to/Chrome", "--user-data-dir"])
        )
    }

    // MARK: - DW-2.3: basename label mapping

    let fakeDefaultDir = "/Users/test/Library/Application Support/Google/Chrome"

    // DW-2.3: a /tmp CDP dir maps to its basename.
    func test_DW_2_3_label_for_tmp_cdp_dir() {
        XCTAssertEqual(
            ChromeInstancePolicy.instanceLabel(
                forUserDataDir: "/tmp/chrome-cdp-profile",
                defaultDataDir: fakeDefaultDir
            ),
            "chrome-cdp-profile"
        )
        XCTAssertEqual(
            ChromeInstancePolicy.instanceLabel(
                forUserDataDir: "/tmp/chrome-cdp-profile-2",
                defaultDataDir: fakeDefaultDir
            ),
            "chrome-cdp-profile-2"
        )
    }

    // DW-2.3: the default Chrome data dir (the real browser) yields no label,
    // including a trailing-slash variant.
    func test_DW_2_3_no_label_for_default_dir() {
        XCTAssertNil(
            ChromeInstancePolicy.instanceLabel(
                forUserDataDir: fakeDefaultDir,
                defaultDataDir: fakeDefaultDir
            )
        )
        XCTAssertNil(
            ChromeInstancePolicy.instanceLabel(
                forUserDataDir: fakeDefaultDir + "/",
                defaultDataDir: fakeDefaultDir
            )
        )
    }

    // DW-2.3: absent dir (nil) yields no label.
    func test_DW_2_3_no_label_when_nil() {
        XCTAssertNil(
            ChromeInstancePolicy.instanceLabel(forUserDataDir: nil, defaultDataDir: fakeDefaultDir)
        )
        XCTAssertNil(
            ChromeInstancePolicy.instanceLabel(forUserDataDir: "", defaultDataDir: fakeDefaultDir)
        )
    }

    // DW-2.3: end-to-end — a separate instance's bare "Default" title plus a
    // non-default user-data-dir produces subtitle "Default · <basename>".
    func test_DW_2_3_enrich_appends_dir_basename_to_subtitle() {
        let enricher = ChromeEnricher()
        let result = enricher.enrich(
            windowTitle: "New Tab - Google Chrome",
            userDataDir: "/tmp/chrome-cdp-profile"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .chrome)
        // Subtitle ends with the dir label; the lead is the default profile
        // name (host-dependent) or the bare "Default" fallback, so assert the
        // separator + basename suffix rather than the full string.
        XCTAssertTrue(
            result?.subtitle.hasSuffix("· chrome-cdp-profile") ?? false,
            "subtitle was: \(result?.subtitle ?? "nil")"
        )
        XCTAssertEqual(result?.title, "New Tab")
    }

    // MARK: - DW-2.4: distinct stable IDs for same profile, different dir

    func test_DW_2_4_distinct_stable_ids_for_same_profile_diff_dir() {
        let enricher = ChromeEnricher()
        let a = enricher.enrich(
            windowTitle: "New Tab - Google Chrome",
            userDataDir: "/tmp/chrome-cdp-profile"
        )
        let b = enricher.enrich(
            windowTitle: "New Tab - Google Chrome",
            userDataDir: "/tmp/chrome-cdp-profile-2"
        )
        XCTAssertNotNil(a?.stableIDSuffix)
        XCTAssertNotNil(b?.stableIDSuffix)
        // Same profile display name ("Default"), different user-data-dir ->
        // distinct stable-id suffixes (no picker collision).
        XCTAssertNotEqual(a?.stableIDSuffix, b?.stableIDSuffix)
        // And the default instance (no dir) is distinct from both, with the
        // dir folded only into the separate-instance suffixes.
        let def = enricher.enrich(windowTitle: "New Tab - Google Chrome", userDataDir: nil)
        XCTAssertNotEqual(def?.stableIDSuffix, a?.stableIDSuffix)
        XCTAssertFalse(def?.stableIDSuffix.contains("@") ?? true)
    }

    // MARK: - DW-2.2: per-PID reader failure + cache behavior

    // DW-2.2 (dirty): a non-existent PID yields nil with no crash.
    func test_DW_2_2_reader_nil_on_dead_pid() {
        let reader = ProcessArgsReader()
        // PID 999999 is well above any live PID on macOS — KERN_PROCARGS2
        // returns an error, which the reader must turn into nil, not a crash.
        XCTAssertNil(reader.userDataDir(forPID: 999_999))
    }

    // DW-2.2: the result is cached per PID (second call returns the same value
    // and does not re-read). We assert idempotency for both a dead PID (nil)
    // and the current test process (whichever value, stable across calls).
    func test_DW_2_2_reader_caches_result() {
        let reader = ProcessArgsReader()
        let first = reader.userDataDir(forPID: 999_999)
        let second = reader.userDataDir(forPID: 999_999)
        XCTAssertEqual(first, second)
        XCTAssertNil(first)

        // Live PID: the reader returns a stable value across calls (cached).
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let a = reader.userDataDir(forPID: selfPID)
        let b = reader.userDataDir(forPID: selfPID)
        XCTAssertEqual(a, b)
    }
}
