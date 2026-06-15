//
// ChromeTitlePolicy.swift
// GridServer
//
// Pure decision helpers for Chrome AX-title handling. No I/O, no actor
// isolation, no side effects — unit-testable off the AX boundary.
//
// Two decisions live here:
//   1. Whether an incoming AX title may overwrite a cached one (clobber guard).
//   2. Whether a Chrome window's cached axTitle is good enough to enrich from,
//      or must be re-polled because it lacks the profile suffix.
//

import Foundation

// Whether a title carries the Chrome profile suffix "- Google Chrome - <Profile>".
enum ChromeTitleClass: Equatable {
    case hasProfileSuffix
    case missingProfileSuffix
}

// Whether the enrichment path should enrich from the cached axTitle as-is,
// or re-poll AX first because the cached title lacks the profile.
enum ChromeTitleDecision: Equatable {
    case enrichFromCached
    case repoll
}

enum ChromeTitlePolicy {
    static let chromeBundleID = "com.google.Chrome"

    // Mirrors ChromeEnricher.profilePattern: "- <Browser> - <Profile>" at the
    // tail of the title. Presence of capture group 1 means the profile is
    // carried in the title.
    private static let profileSuffixPattern = try! NSRegularExpression(
        pattern: #"- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$"#
    )

    // Classify whether a (possibly nil/empty) AX title carries the profile
    // suffix. Empty, nil, bare-browser, and CGWindow-fallback titles are all
    // missingProfileSuffix.
    static func classify(axTitle: String?) -> ChromeTitleClass {
        guard let title = axTitle, !title.isEmpty else {
            return .missingProfileSuffix
        }
        let ns = title as NSString
        let range = NSRange(location: 0, length: ns.length)
        if profileSuffixPattern.firstMatch(in: title, range: range) != nil {
            return .hasProfileSuffix
        }
        return .missingProfileSuffix
    }

    // Re-poll only for Chrome windows whose cached title lacks the profile
    // suffix. Non-Chrome windows, and Chrome windows whose cached title already
    // carries the profile, enrich from the cached value.
    static func decide(bundleID: String, cachedAXTitle: String?) -> ChromeTitleDecision {
        guard bundleID == chromeBundleID else {
            return .enrichFromCached
        }
        switch classify(axTitle: cachedAXTitle) {
        case .hasProfileSuffix:
            return .enrichFromCached
        case .missingProfileSuffix:
            return .repoll
        }
    }

    // Clobber guard: an empty incoming title is never information worth
    // persisting over a non-empty cached one. Returns false to skip the write.
    static func shouldOverwriteAXTitle(existing: String?, incoming: String) -> Bool {
        if incoming.isEmpty, let existing = existing, !existing.isEmpty {
            return false
        }
        return true
    }
}
