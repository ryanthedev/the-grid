# Plan: Chrome Profile Identity in the Picker

**Created:** 2026-06-14
**Status:** in-progress
**Started:** 2026-06-14 16:30
**Current Phase:** 2
**Complexity:** simple

---

## Context

**Problem:** theGrid's picker labels every Chrome window `com.google.Chrome` with no profile, because (a) an unguarded `axTitle` overwrite in `handleWindowTitleChanged` clobbers the profile-bearing AX title with empty strings delivered by `kAXTitleChangedNotification`, and (b) separate Chrome instances (distinct `--user-data-dir`, e.g. CDP automation profiles) are indistinguishable from the real browser.

The profile lives in the AX window title: `"<page> - Google Chrome - <ProfileName> (<email>)"`. theGrid's polled AX read captures it correctly (proven by reproducing the exact `AXUIElementCreateApplication` → `kAXWindows` → `_AXUIElementGetWindow` match → `kAXTitle` path); the value is then overwritten with `""`. The `ChromeEnricher` parser + `Local State` map already handle the format — they are simply starved of input. Full root-cause analysis: `.code-foundations/research/2026-06-14-chrome-profile-identity-picker.md`.

**Goal:** the picker shows `Ryan (ryanthedev.com)` / `Victoria and Ryan` for in-process profiles, and `Default · chrome-cdp-profile` for separate-instance windows — verified live.

## Constraints

- **No subprocesses** for reading process args — use `sysctl` `KERN_PROCARGS2` (matches `ChromeEnricher`'s file-I/O-only, no-subprocess convention).
- **Reuse existing seams** — `ChromeEnricher` parser, `Local State` `info_cache` map, and `refreshWindowAXProperties` (`StateManager.swift:690`). Do not reimplement title parsing or AX reads.
- **Follow project conventions** (`docs/code-standards.md`): no inline trailing comments; `jlog`/`JSONLogger.shared.log` not `print`; extract branching decision logic as pure, testable `*Policy`-style `static` helpers off the AX/SkyLight boundary; named-result types over bare `Bool` where it aids clarity; `[weak self]` in escaping closures.
- **Subtitle format** (confirmed): `<Profile> (<email>)`, falling back to `<Profile>` when no signed-in email; append `· <dir-basename>` for separate `--user-data-dir` instances.
- **Test budget**: 3–5 targeted tests per phase (project `CLAUDE.md`); pure helpers fully covered.

---

## Implementation Phases

### Phase 1: Fix AX-title capture so in-process profiles surface
**Skills:** code-foundations:cc-defensive-programming
**Gate:** Standard

**Goal:** The profile name surfaces in the picker for windows of the main multi-profile Chrome (Ryan / Omniping / Victoria and Ryan), by stopping the empty-title clobber and re-polling the AX title when the cached one lacks the profile suffix.

**Scope:**
- IN: guard `handleWindowTitleChanged` (`StateManager.swift:1898`) so an empty title never overwrites a non-empty `axTitle` (the single unguarded writer of five); a pure predicate that decides whether a title carries the ` - Google Chrome - <profile>` suffix; re-poll via the existing `refreshWindowAXProperties` in the enrichment path (`WindowSource.swift:51-63` / `WindowEnricher.swift:39,58`) when a `com.google.Chrome` window's `axTitle` is empty or suffix-less; feed the resulting rich title to `ChromeEnricher`. The re-poll fires **only during picker-open enrichment** (`WindowEnricher`), not in response to live `kAXTitleChangedNotification` events.
- OUT: `--user-data-dir` / separate-instance distinction (Phase 2); browsers other than what `ChromeEnricher` already lists; tab-level enumeration; live re-render on profile switch within an already-listed window.

**Edge cases:**
- Empty title from `kAXTitleChangedNotification` (`getWindowTitle` returns `""` on `.success`) — must not clobber (GC-1, RF-12).
- Cached title is the CGWindow fallback (`"Monkeytype …"`, no ` - Google Chrome` suffix) — triggers re-poll.
- Re-poll still empty / AX messaging timeout / window destroyed (`refreshWindowAXProperties` returns `nil`) — degrade to the prior subtitle; never persist an empty `axTitle` and never crash.
- Non-Chrome windows unaffected (re-poll gated on `bundleID == com.google.Chrome` + missing suffix).

**Produces:** `WindowState.axTitle` reliably carries `"<page> - Google Chrome - <Profile> (<email>)"` whenever AX exposes it, and the enrichment path resolves a profile from it. **Seam contract consumed by Phase 2:** `ChromeEnricher.enrich(windowTitle: String) -> EnrichmentResult?` is the single profile-resolution point; Phase 2 widens it to `enrich(windowTitle: String, userDataDir: String? = nil)` (and threads the same optional param through `WindowEnricher.enrich(bundleID:pid:title:axTitle:)`) so the instance label is composed into `EnrichmentResult.subtitle`/`.stableIDSuffix` in one place. Phase 1 leaves the signature single-arg; the `userDataDir: String? = nil` default keeps Phase 1 call sites unbroken.

**Done when:**
- [ ] DW-1.1: An empty title delivered via `kAXTitleChangedNotification` leaves a previously-populated `WindowState.axTitle` unchanged (guard added at the single unguarded writer).
- [ ] DW-1.2: A pure helper classifies whether a title carries the Chrome profile suffix (unit-tested directly); when a `com.google.Chrome` window's cached `axTitle` is empty or suffix-less, the enrichment path re-polls via `refreshWindowAXProperties`, emits an observable `jlog("chrome.repoll", data: ["wid": …])` event, and enriches from the returned title.
- [ ] DW-1.3: Picker subtitle for in-process profiles reads `"<Profile> (<email>)"`, or `"<Profile>"` when the profile has no signed-in email — verified live for Ryan, Omniping, and Victoria and Ryan.
- [ ] DW-1.4: Re-poll failure (window gone or AX returns empty) degrades to the prior subtitle with no crash and no empty-string write to `axTitle`.

---

### Phase 2: Distinguish separate `--user-data-dir` instances
**Skills:** code-foundations:cc-defensive-programming
**Gate:** Standard

**Goal:** Separate Chrome instances (distinct `--user-data-dir`, e.g. the `/tmp` CDP automation profiles) read as `Default · <dir-basename>` and get unique stable IDs, instead of all collapsing to bare `com.google.Chrome` / colliding `Default`.

**Depends on:** Phase 1. Consumes the seam contract: widens `ChromeEnricher.enrich(windowTitle:)` to `enrich(windowTitle:, userDataDir: String? = nil)` and threads `userDataDir` through `WindowEnricher.enrich(bundleID:pid:title:axTitle:)`; the resolved per-PID `user-data-dir` (from this phase's reader) is passed in, and the label is composed into `EnrichmentResult.subtitle`/`.stableIDSuffix` inside `ChromeEnricher`.

**Scope:**
- IN: a per-PID reader that fetches a process's launch args via `sysctl` `KERN_PROCARGS2`, cached per-PID; a pure helper that extracts `--user-data-dir` from an argv array (both `--flag=value` and `--flag value` forms); map a non-default `user-data-dir` to its basename label; append `· <basename>` to the Chrome subtitle and fold the dir into `stableIDSuffix` so instances sharing a profile name do not collide.
- OUT: `--profile-directory` parsing (a separate instance's sole profile is treated as `Default`); non-Chrome apps; watching for instances launched after enumeration (picked up on next picker open); per-tab attribution.

**Edge cases:**
- `KERN_PROCARGS2` returns an error, a truncated buffer, or undecodable bytes — return `nil`, treat as default instance, log once; never crash (GC-1, SO-2, RF-12).
- `--user-data-dir` absent → default instance → no label.
- `user-data-dir` resolves to the default `~/Library/Application Support/Google/Chrome` → no label (this is the real browser).
- Both arg forms (`--user-data-dir=/tmp/x` and `--user-data-dir /tmp/x`).
- PID disappears between enumeration and read → `nil`, no label.

**Produces:** Chrome subtitle `"Default · <basename>"` for separate instances and unchanged `"<Profile> (<email>)"` for the default instance; `stableIDSuffix` carries a `user-data-dir` discriminator so two instances with the same profile display name get distinct picker IDs.

**Done when:**
- [ ] DW-2.1: A pure helper extracts the `--user-data-dir` value from an argv array, handling both `--flag=value` and `--flag value`, and returns `nil` when the flag is absent.
- [ ] DW-2.2: A per-PID reader returns the `user-data-dir` for a Chrome PID via `KERN_PROCARGS2`, caches the result, and returns `nil` (logged once, no crash) on syscall failure or a truncated/undecodable buffer.
- [ ] DW-2.3: Separate-instance windows show subtitle `"Default · <basename>"` (e.g. `"Default · chrome-cdp-profile"`); the default instance shows no dir label — verified live for the two `/tmp` CDP instances (PIDs reading `/tmp/chrome-cdp-profile` and `/tmp/chrome-cdp-profile-2`).
- [ ] DW-2.4: Two instances that share a profile display name produce distinct `stableID`s (no collision in the picker list).

---

## Test Coverage

**Level:** Targeted (project `CLAUDE.md`: 3–5 tests/phase, prove the approach). Pure helpers covered fully; behavior covered with one representative + one dirty case each. Pattern: `test_DW_<phase>_<item>_<descriptor>`, XCTest, co-located in `grid-server/Tests/GridServerTests/`.

## Test Plan

Phase 1:
- [ ] DW-1.1 (dirty): feeding an empty title through the title-change path leaves a prior non-empty `axTitle` intact.
- [ ] DW-1.2: profile-suffix predicate returns true for `"X - Google Chrome - Ryan (ryanthedev.com)"`, false for `"X - Google Chrome"` and `""` (drives the re-poll decision).
- [ ] DW-1.3: `ChromeEnricher.enrich("X - Google Chrome - Ryan (ryanthedev.com)")` yields subtitle `"Ryan (ryanthedev.com)"`; a no-email profile yields just the name (extend existing `ChromeEnricher` tests if present).
- [ ] DW-1.3b (dirty): a suffixed title whose profile name has no matching `Local State` entry falls back to the bare profile name (no crash, no empty subtitle).
- [ ] DW-1.4 (dirty): a `nil`/empty re-poll result yields the fallback subtitle and does not write an empty `axTitle`.

Phase 2:
- [ ] DW-2.1: `extractUserDataDir(argv)` → `"/tmp/chrome-cdp-profile"` for both `--user-data-dir=/tmp/chrome-cdp-profile` and `["--user-data-dir","/tmp/chrome-cdp-profile"]`; `nil` when absent.
- [ ] DW-2.2 (dirty): the per-PID reader returns `nil` (no crash) when given a non-existent PID / simulated syscall failure.
- [ ] DW-2.3: basename + label mapping — `/tmp/chrome-cdp-profile` → `"chrome-cdp-profile"`; the default Chrome data dir → no label.
- [ ] DW-2.4 (dirty): two synthetic instances with the same profile name but different `user-data-dir` produce different `stableID`s.

---

## Notes

- The fix is a clobber guard + re-poll, not a new read path — the polled AX read already returns the full profile-suffixed title (verified). Do not add a System Events / AppleScript fallback.
- Prefer guarding at `handleWindowTitleChanged` (single intent-local chokepoint) over `getWindowTitle`, so the "empty AX title is never information" rule is stated where `axTitle` is owned.
- `KERN_PROCARGS2` layout: `[argc:Int32][exec_path\0][padding\0…][argv0\0 argv1\0 …][env…]`. Parse argc, skip the exec path, then read `argc` NUL-terminated args. Bound every read to `sysctl`'s returned length.
- Separate-instance args are immutable for a process lifetime → cache by PID; evict when the PID leaves `state.applications`.
- Open (cosmetic, safe to decide in build): exact separator glyph (`·`) and whether the default-instance subtitle ever shows a label — current decision is no label for default.

---

## Execution Log

### Phase 1: Fix AX-title capture (Gate: Standard)
- [x] BUILD: Discovery + design + implementation (stub → implement → validate) complete
- [x] REVIEW: SKIPPED — tests are gate
- [x] Committed
Commit: cbdcfdb
Summary: Stopped the empty-title clobber (guarded `handleWindowTitleChanged`, the lone unguarded of five `axTitle` writers) and added picker-open re-poll via `refreshWindowAXProperties` (logged `chrome.repoll`) when a Chrome window's cached `axTitle` is empty/suffix-less, gated by a new pure `ChromeTitlePolicy` (suffix predicate + re-poll decision + overwrite guard, named-result enums, no I/O). `ChromeEnricher.enrich(windowTitle:)` deliberately left single-arg for Phase 2 to widen with `userDataDir`. 9 new tests, 308/308 suite green, clean build.
