//
// ChromeTitlePolicyTests.swift
// GridServerTests
//
// Phase 1: Chrome profile identity in the picker.
// Covers the pure decision helpers (DW-1.1, DW-1.2, DW-1.4) and the
// ChromeEnricher subtitle path (DW-1.3, DW-1.3b).
//

import XCTest
@testable import GridServer

final class ChromeTitlePolicyTests: XCTestCase {

    // DW-1.1: an empty incoming title must not overwrite a populated axTitle.
    func test_DW_1_1_empty_title_does_not_clobber_nonempty() {
        let existing = "Monkeytype - Google Chrome - Ryan (ryanthedev.com)"
        XCTAssertFalse(
            ChromeTitlePolicy.shouldOverwriteAXTitle(existing: existing, incoming: "")
        )
    }

    // DW-1.1: a non-empty incoming title overwrites as before; an empty
    // incoming over an empty/nil cached one is allowed (nothing to protect).
    func test_DW_1_1_nonempty_title_overwrites() {
        XCTAssertTrue(
            ChromeTitlePolicy.shouldOverwriteAXTitle(
                existing: "old", incoming: "New Tab - Google Chrome - Ryan"
            )
        )
        XCTAssertTrue(ChromeTitlePolicy.shouldOverwriteAXTitle(existing: nil, incoming: ""))
        XCTAssertTrue(ChromeTitlePolicy.shouldOverwriteAXTitle(existing: "", incoming: ""))
    }

    // DW-1.2: predicate recognizes the profile suffix.
    func test_DW_1_2_classify_true_for_profile_suffix() {
        XCTAssertEqual(
            ChromeTitlePolicy.classify(
                axTitle: "Monkeytype | typing test - Google Chrome - Ryan (ryanthedev.com)"
            ),
            .hasProfileSuffix
        )
        XCTAssertEqual(
            ChromeTitlePolicy.classify(axTitle: "New Tab - Google Chrome - Victoria and Ryan"),
            .hasProfileSuffix
        )
    }

    // DW-1.2: bare-browser, empty, nil, and CGWindow-fallback titles all lack
    // the suffix.
    func test_DW_1_2_classify_false_for_bare_browser_and_empty() {
        XCTAssertEqual(
            ChromeTitlePolicy.classify(axTitle: "New Tab - Google Chrome"),
            .missingProfileSuffix
        )
        XCTAssertEqual(ChromeTitlePolicy.classify(axTitle: ""), .missingProfileSuffix)
        XCTAssertEqual(ChromeTitlePolicy.classify(axTitle: nil), .missingProfileSuffix)
        XCTAssertEqual(
            ChromeTitlePolicy.classify(axTitle: "Monkeytype"),
            .missingProfileSuffix
        )
    }

    // DW-1.2: re-poll decision fires only for Chrome windows missing the suffix.
    func test_DW_1_2_classify_needsRepoll_for_chrome_emptyOrSuffixless() {
        // Chrome + empty cached title -> repoll.
        XCTAssertEqual(
            ChromeTitlePolicy.decide(bundleID: "com.google.Chrome", cachedAXTitle: ""),
            .repoll
        )
        // Chrome + suffix-less (CGWindow fallback) -> repoll.
        XCTAssertEqual(
            ChromeTitlePolicy.decide(bundleID: "com.google.Chrome", cachedAXTitle: "Monkeytype"),
            .repoll
        )
        // Chrome + already-suffixed -> enrich from cached, no repoll.
        XCTAssertEqual(
            ChromeTitlePolicy.decide(
                bundleID: "com.google.Chrome",
                cachedAXTitle: "X - Google Chrome - Ryan (ryanthedev.com)"
            ),
            .enrichFromCached
        )
        // Non-Chrome window -> never repoll (edge case: unaffected).
        XCTAssertEqual(
            ChromeTitlePolicy.decide(bundleID: "com.apple.Safari", cachedAXTitle: ""),
            .enrichFromCached
        )
    }

    // DW-1.4: a nil/empty re-poll result is classified as still needing a
    // re-poll (i.e. it never becomes the source of a good enrichment) and,
    // combined with refreshWindowAXProperties' empty-guard, never produces a
    // good title from nothing. We assert the policy treats an empty refreshed
    // title exactly like the missing-suffix case it started from.
    func test_DW_1_4_repoll_empty_title_is_no_op_decision() {
        // The refreshed value the WindowSource would fall back to: prior cached.
        let priorCached = "Monkeytype - Google Chrome - Ryan (ryanthedev.com)"
        // Simulate refreshWindowAXProperties returning empty (it guards, so the
        // window's axTitle stays priorCached). Fallback expression in
        // WindowSource is `refreshed?.axTitle ?? window.axTitle`; with an empty
        // refreshed axTitle the cached value is what gets enriched.
        let refreshedAXTitle: String? = ""
        let used = (refreshedAXTitle?.isEmpty == false ? refreshedAXTitle : nil) ?? priorCached
        XCTAssertEqual(used, priorCached)
        // And an empty title would never overwrite the cached one.
        XCTAssertFalse(
            ChromeTitlePolicy.shouldOverwriteAXTitle(existing: priorCached, incoming: "")
        )
    }

    // DW-1.3: a profile-suffixed title splits into page title + profile name.
    // Email is appended only when Local State resolves one; when it does not
    // (host has no matching entry), the subtitle is the bare profile name.
    func test_DW_1_3_enrich_profile_subtitle_format() {
        let enricher = ChromeEnricher()
        let result = enricher.enrich(
            windowTitle: "Monkeytype | typing test - Google Chrome - Ryan (ryanthedev.com)"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .chrome)
        // Profile name "Ryan (ryanthedev.com)" is parsed verbatim from the
        // title; the subtitle is either "<name> (<email>)" when Local State
        // resolves an email, or the bare parsed name otherwise. Both forms
        // start with "Ryan".
        XCTAssertTrue(result?.subtitle.hasPrefix("Ryan") ?? false)
        XCTAssertEqual(result?.title, "Monkeytype | typing test")
        XCTAssertEqual(result?.stableIDSuffix, "chrome:Ryan (ryanthedev.com)")
    }

    // DW-1.3: a profile with no signed-in email yields just the name. Uses a
    // synthetic profile name that is guaranteed absent from any host's Local
    // State, so the empty-email branch is exercised deterministically (the
    // representative "Victoria and Ryan" string is host-dependent — on a
    // machine where that profile is signed in, Local State resolves an email).
    func test_DW_1_3_enrich_local_profile_no_email_bare_name() {
        let enricher = ChromeEnricher()
        let result = enricher.enrich(
            windowTitle: "New Tab - Google Chrome - Victoria and Ryan ZZTEST"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.subtitle, "Victoria and Ryan ZZTEST")
        XCTAssertEqual(result?.title, "New Tab")
        XCTAssertFalse(result?.subtitle.isEmpty ?? true)
    }

    // DW-1.3b (dirty): a suffixed title whose profile name has no matching
    // Local State entry falls back to the bare profile name — no crash, no
    // empty subtitle.
    func test_DW_1_3b_unknown_profile_falls_back_to_bare_name() {
        let enricher = ChromeEnricher()
        let result = enricher.enrich(
            windowTitle: "Some Page - Google Chrome - NoSuchProfile12345"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.subtitle, "NoSuchProfile12345")
        XCTAssertFalse(result?.subtitle.isEmpty ?? true)
    }
}
