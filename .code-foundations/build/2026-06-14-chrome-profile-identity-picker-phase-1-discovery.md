# Discovery + Design: Phase 1 - Fix AX-title capture so in-process profiles surface

## Files Found

| File | Role in this phase |
|------|--------------------|
| `grid-server/Sources/GridServer/StateManager.swift` | `handleWindowTitleChanged` (:1894, unguarded writer) and `refreshWindowAXProperties` (:690, re-poll helper) |
| `grid-server/Sources/GridServer/Picker/WindowSource.swift` | Picker discovery loop; has `windowID`, `bundleID`, `StateManager.shared` access — the natural re-poll site |
| `grid-server/Sources/GridServer/Picker/Enrichment/WindowEnricher.swift` | `enrich(bundleID:pid:title:axTitle:)` routes Chrome titles to `ChromeEnricher` (:39, :58) |
| `grid-server/Sources/GridServer/Picker/Enrichment/ChromeEnricher.swift` | `enrich(windowTitle:)` parser + Local State map — already correct, starved of input |
| `grid-server/Sources/GridServer/Picker/Enrichment/EnrichmentTypes.swift` | `EnrichmentResult` shape |
| `grid-server/Sources/GridServer/Grid/*Policy.swift` | Convention exemplars for pure decision helpers |

## Current State

- `handleWindowTitleChanged` (`StateManager.swift:1894-1902`) writes `window.axTitle = title` unconditionally — the single unguarded writer of five. An empty `""` from `kAXTitleChangedNotification` clobbers a profile-bearing title.
- `refreshWindowAXProperties` (`StateManager.swift:690-708`) re-reads AX props and at :703 already guards `if let axTitle = axProps.title, !axTitle.isEmpty` — so a re-poll that returns empty will NOT write an empty `axTitle`, and it returns `nil` when the window is no longer tracked. This is exactly the degrade-safe behavior DW-1.4 needs; we reuse it as-is.
- `ChromeEnricher.enrich(windowTitle:)` already parses `"<page> - Google Chrome - <Profile>"` → subtitle `"<Profile> (<email>)"` (email from Local State `info_cache`), falling back to bare `<Profile>` when the email lookup misses or is empty. DW-1.3 and DW-1.3b are already satisfied by existing code; they just need input + tests.
- `WindowEnricher.enrich` already takes `axTitle: String? = nil` and feeds `axTitle ?? title` to `ChromeEnricher`. No signature change needed in Phase 1.
- `WindowSource.discover()` already passes `window.axTitle` into the enricher (:62). It holds `windowIDStr`, `bundleID`, and can `await StateManager.shared.refreshWindowAXProperties(...)`.

## Gaps

| Gap | Resolution |
|-----|------------|
| Unguarded empty-title clobber | Add guard in `handleWindowTitleChanged` (DW-1.1) |
| No pure predicate for the profile suffix | New `ChromeTitlePolicy` pure helper with named result (DW-1.2) |
| Enrichment never re-polls when cached `axTitle` is empty/suffix-less | Re-poll in `WindowSource.discover()` gated on Chrome bundle + policy decision, emit `jlog("chrome.repoll", data:["wid":…])` (DW-1.2) |
| No tests for ChromeEnricher subtitle path | Add deterministic tests (DW-1.3, DW-1.3b) |

## Code Standards

- `jlog(...)` not `print()`; `chrome.repoll` event code (scope-first, dot-separated lowercase).
- No inline trailing comments — comments above the line.
- Extract branching decision logic as a pure, testable `*Policy` `static` helper with a named-result type, not a bare `Bool` (chosen: `ChromeTitlePolicy.classify(...) -> ChromeTitleDecision`).
- `[weak self]` not needed — re-poll is a direct `await` in a struct method, no escaping closure.
- Tests: XCTest in `grid-server/Tests/GridServerTests/`, named `test_DW_1_<item>_<descriptor>`.

## Test Infrastructure

XCTest, co-located in `grid-server/Tests/GridServerTests/`. Pure-logic tests preferred; avoid AX/SkyLight in tests by testing pure helpers. `ChromeEnricher` reads `~/Library/.../Local State` lazily — tests assert on the parser branches that do NOT require a Local State entry (suffix present → subtitle derives from the title's profile name; missing email/missing entry → bare name), which is deterministic regardless of the host's Chrome install.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|----------------|--------|------------|
| DW-1.1 | Empty title via notification leaves populated `axTitle` unchanged (guard at the single unguarded writer) | COVERED | `test_DW_1_1_empty_title_does_not_clobber_nonempty` (policy), `test_DW_1_1_nonempty_title_overwrites` (policy) |
| DW-1.2 | Pure helper classifies profile suffix; enrichment re-polls + emits `jlog("chrome.repoll")` + enriches from returned title | COVERED | `test_DW_1_2_classify_true_for_profile_suffix`, `test_DW_1_2_classify_false_for_bare_browser_and_empty`, `test_DW_1_2_classify_needsRepoll_for_chrome_emptyOrSuffixless` |
| DW-1.3 | Picker subtitle reads `"<Profile> (<email>)"` or `"<Profile>"` when no email | COVERED | `test_DW_1_3_enrich_profile_with_email_when_present` (asserts page-title split + `chrome:` stableID + bare-name fallback path), `test_DW_1_3_enrich_local_profile_no_email_bare_name` |
| DW-1.3b | Suffixed title with no Local State match → bare profile name, no crash, no empty subtitle | COVERED | `test_DW_1_3b_unknown_profile_falls_back_to_bare_name` |
| DW-1.4 | Re-poll failure degrades to prior subtitle, no crash, no empty-string write to `axTitle` | COVERED | `test_DW_1_4_repoll_empty_title_is_no_op_decision` (policy: empty re-poll result keeps prior title), plus the reused `refreshWindowAXProperties` :703 empty-guard documented as the runtime guarantee |

**All items COVERED:** YES (5 DW-IDs in prompt == 5 rows here)

## Design Decisions

**Pure helper: `ChromeTitlePolicy` (new `Picker/Enrichment/ChromeTitlePolicy.swift`).**
Named-result type over bare `Bool` per code standards:

```swift
enum ChromeTitleClass: Equatable {
    // "<page> - Google Chrome - <Profile>" — profile is in the title
    case hasProfileSuffix
    // "<page> - Google Chrome" or "" or CGWindow fallback — profile NOT in the title
    case missingProfileSuffix
}

enum ChromeTitleDecision: Equatable {
    case enrichFromCached      // not Chrome, or title already carries the profile
    case repoll                // Chrome window whose cached axTitle is empty/suffix-less
}

enum ChromeTitlePolicy {
    static func classify(axTitle: String?) -> ChromeTitleClass
    static func decide(bundleID: String, cachedAXTitle: String?) -> ChromeTitleDecision
    // DW-1.1 guard predicate — empty title is never information to persist
    static func shouldOverwriteAXTitle(existing: String?, incoming: String) -> Bool
}
```

- `classify`: `hasProfileSuffix` iff the title matches `- (Google Chrome|Brave|Chromium|Microsoft Edge) - <something>` (mirrors `ChromeEnricher.profilePattern`). Empty / bare-browser / CGWindow-fallback → `missingProfileSuffix`.
- `decide`: `repoll` only when `bundleID == com.google.Chrome` AND `classify(cachedAXTitle) == .missingProfileSuffix`. Everything else → `enrichFromCached`. This gates the re-poll on Chrome + missing suffix (non-Chrome windows untouched — edge case covered).
- `shouldOverwriteAXTitle`: `false` when `incoming.isEmpty` and `existing` is non-empty; `true` otherwise. Drives the DW-1.1 guard in `handleWindowTitleChanged`.

**DW-1.1 integration:** `handleWindowTitleChanged` guards with `ChromeTitlePolicy.shouldOverwriteAXTitle(existing: window.axTitle, incoming: title)` before assigning. `lastUpdated`/`metadata.update()` still run only when we actually write (a no-op write should not churn state). This matches the existing four guarded writers' intent.

**DW-1.2 / DW-1.4 integration (re-poll in `WindowSource.discover()`):**
Before enriching, when `ChromeTitlePolicy.decide(bundleID:cachedAXTitle:window.axTitle) == .repoll`:
1. `jlog("chrome.repoll", data: ["wid": wid])`.
2. `let refreshed = await StateManager.shared.refreshWindowAXProperties(windowID)`.
3. Use `refreshed?.axTitle ?? window.axTitle` as the `axTitle` passed to the enricher.

Because `refreshWindowAXProperties` (a) returns `nil` if the window is gone and (b) only writes `axTitle` when non-empty (:703), a failed/empty re-poll leaves the prior `axTitle` in place and we fall back to it — no crash, no empty write (DW-1.4). The re-poll fires ONLY here in picker enrichment, never in the notification path (the notification handler only guards, it does not re-poll).

**Seam contract preserved:** `ChromeEnricher.enrich(windowTitle:)` stays single-arg; `WindowEnricher.enrich(...axTitle:)` unchanged. Phase 2 widens both — Phase 1 leaves them clean.

## Defensive-programming notes (cc-defensive-programming)

- GC-1 / RF-12: the empty AX title is untrusted transient input crossing the AX boundary; the guard rejects it rather than letting it overwrite known-good state (no fallback that masks the good value).
- The re-poll degrade path uses "return previous answer" (the cached `axTitle`) — appropriate here (display/robustness domain, not correctness-critical), and the failure is observable via `jlog("chrome.repoll")`.
- No empty catch blocks, no assertions used for runtime conditions, no executable code in assertions. The policy helpers are pure (no I/O, no side effects).

## Prerequisites

- [x] Required files exist
- [x] `refreshWindowAXProperties` already guards empty + returns nil on missing window (DW-1.4 substrate present)
- [x] `ChromeEnricher` already implements the subtitle format (DW-1.3 / 1.3b substrate present)
- [x] No prior-phase dependency (Phase 1 is first)

## Live verification handoff (for orchestrator)

The worktree build cannot drive the live picker UI. After `make run` on the running server, the orchestrator confirms DW-1.3 live by:
1. Open the picker against the real multi-profile Chrome (PID with `Ryan` / `Omniping` / `Victoria and Ryan`).
2. Inspect picker subtitles — expect `Ryan (ryanthedev.com)`, `Omniping (omniping.dev)`, `Victoria and Ryan` (no email).
3. Confirm the re-poll fired: `grep '"ev":"chrome.repoll"' ~/.local/state/thegrid/thegrid-server.json | tail` shows entries with the Chrome `wid`s.
4. Confirm no empty clobber: `mcp__thegrid__dump` (or `thegrid` state dump) for the Chrome windows shows non-empty `axTitle` carrying the ` - Google Chrome - <Profile>` suffix.

## Recommendation

BUILD. The bug is a one-line guard plus a gated re-poll reusing existing seams; the parser and the empty-guard substrate already exist. No plan deviation, no new scope.
