# Discovery + Design: Phase 2 - Distinguish separate `--user-data-dir` instances

## Files Found

| File | Role in this phase |
|------|--------------------|
| `grid-server/Sources/GridServer/Picker/Enrichment/ChromeEnricher.swift` | `enrich(windowTitle:)` — the single profile-resolution point; widened to accept `userDataDir` and compose the `· <basename>` label + stableID discriminator |
| `grid-server/Sources/GridServer/Picker/Enrichment/WindowEnricher.swift` | `enrich(bundleID:pid:title:axTitle:)` — threads `userDataDir` to `ChromeEnricher`; owns the per-PID reader |
| `grid-server/Sources/GridServer/Picker/WindowSource.swift` | Picker discovery loop; resolves the per-PID `user-data-dir` and passes it to the enricher; `generateStableID` (`.chrome` branch returns the suffix verbatim) |
| `grid-server/Sources/GridServer/Picker/Enrichment/EnrichmentTypes.swift` | `EnrichmentResult` shape (unchanged) |
| `grid-server/Sources/GridServer/Tests/GridServerTests/EventAllowlistTests.swift` | Static allow-list of every `jlog`/`JSONLogger.shared.log` event; the new "log once" failure event MUST be registered here or the suite fails |
| `grid-server/Sources/GridServer/Picker/Enrichment/ChromeTitlePolicy.swift` | Convention exemplar — pure decision helpers off the syscall boundary |

## Current State

- `ChromeEnricher.enrich(windowTitle:)` is single-arg (Phase 1 left it so deliberately). Branch 1 = profile-suffixed title → `EnrichmentResult(subtitle: "<Profile> (<email>)", stableIDSuffix: "chrome:<Profile>")`. Branch 2 = bare browser suffix (`"<page> - Google Chrome"`, no profile) → the default-profile path, `profileLabel = "Default"` when Local State has no default name. **Separate `/tmp` CDP instances are single-profile, so their titles hit Branch 2** and currently all yield `stableIDSuffix: "chrome:Default"` → collision (the bug DW-2.4 fixes).
- `WindowEnricher.enrich(...)` calls `chromeEnricher.enrich(windowTitle: axTitle ?? title)`. No `userDataDir` plumbed yet.
- `WindowSource.discover()` already loops per window with `window.pid` in hand — the natural site to resolve the per-PID `user-data-dir` and pass it down.
- No existing `KERN_PROCARGS2` / `sysctl` argv reader anywhere in `Sources/` — this phase introduces it.
- `generateStableID` `.chrome` branch returns `e.stableIDSuffix` verbatim (already `chrome:`-prefixed), so folding the dir into `stableIDSuffix` inside `ChromeEnricher` is sufficient to produce distinct picker IDs (DW-2.4) with no `WindowSource` change.
- `EventAllowlistTests` statically scans source for emitted events and fails on any not in its allow-list → a new `err.chrome.procargs` (log-once failure) event must be added to the allow-list in the same commit.

## Gaps

| Gap | Resolution |
|-----|------------|
| No pure argv `--user-data-dir` extractor | New pure helper `ChromeInstancePolicy.extractUserDataDir(argv:)` handling `--flag=value` and `--flag value` (DW-2.1) |
| No basename→label mapping / default-dir suppression | Pure helper `ChromeInstancePolicy.instanceLabel(forUserDataDir:)` → `nil` for absent/default dir, else basename (DW-2.3) |
| No per-PID argv reader | New `ProcessArgsReader` (impure boundary) — `KERN_PROCARGS2` via `sysctl`, per-PID cache, `nil` + log-once on failure (DW-2.2) |
| `ChromeEnricher` cannot compose the instance label | Widen `enrich(windowTitle:, userDataDir: String? = nil)`; append `· <basename>` to subtitle and fold dir into `stableIDSuffix` (DW-2.3, DW-2.4) |
| `userDataDir` not threaded | Add `userDataDir` param to `WindowEnricher.enrich(...)`; resolve per-PID in `WindowSource` and pass through |

## Code Standards

- `jlog(...)` / `JSONLogger.shared.log(...)` not `print()`. New failure event `err.chrome.procargs` (scope-first, dot-separated lowercase) — register in `EventAllowlistTests.allowlist`.
- No inline trailing comments — comments above the code.
- Pure decision logic extracted as `static` helpers off the syscall boundary: the argv extractor and basename→label mapping live in a pure `ChromeInstancePolicy`; the `KERN_PROCARGS2` syscall + buffer parsing live in a thin, well-guarded `ProcessArgsReader`.
- Named-result clarity: `instanceLabel` returns `String?` (nil = no label) — self-documenting; a richer enum is not warranted here.
- Tests: XCTest in `grid-server/Tests/GridServerTests/`, named `test_DW_2_<item>_<descriptor>`.

## Test Infrastructure

XCTest, co-located. Pure helpers (`ChromeInstancePolicy`) are fully unit-testable with no I/O. The `ProcessArgsReader` failure path (DW-2.2) is testable by passing a non-existent / dead PID (e.g. `999999`) and asserting `nil` with no crash — exactly as the dispatch notes. The subtitle/stableID composition (DW-2.3, DW-2.4) is tested deterministically through `ChromeEnricher.enrich(windowTitle:userDataDir:)` with a known `userDataDir`, no live picker needed.

## Default Chrome data-dir resolution

The default (real browser) `user-data-dir` is `~/Library/Application Support/Google/Chrome`. Chrome may pass it explicitly or omit it. `instanceLabel(forUserDataDir:)`:
- `nil` input (flag absent) → `nil` (default instance, no label).
- Path that resolves (standardized, trailing-slash-normalized) to `<home>/Library/Application Support/Google/Chrome` → `nil` (the real browser).
- Any other path → its last path component (basename), e.g. `/tmp/chrome-cdp-profile` → `"chrome-cdp-profile"`.

To keep the default-dir comparison pure and host-stable in tests, `ChromeInstancePolicy.instanceLabel(forUserDataDir:defaultDataDir:)` takes the default dir as an injected parameter (production passes the resolved home path; tests pass a fixed one). A thin convenience overload resolves the real home for production callers.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|----------------|--------|------------|
| DW-2.1 | Pure helper extracts `--user-data-dir` from argv (both `=` and space forms), `nil` when absent | COVERED | `test_DW_2_1_extracts_equals_form`, `test_DW_2_1_extracts_space_form`, `test_DW_2_1_nil_when_absent` |
| DW-2.2 | Per-PID reader returns dir via `KERN_PROCARGS2`, caches, returns `nil` (logged once, no crash) on failure/truncation | COVERED | `test_DW_2_2_reader_nil_on_dead_pid` (non-existent PID → nil, no crash), `test_DW_2_2_reader_caches_result` (second call hits cache, same value) |
| DW-2.3 | Separate-instance subtitle `"Default · <basename>"`; default instance no label | COVERED | `test_DW_2_3_label_for_tmp_cdp_dir` (`/tmp/chrome-cdp-profile` → `"chrome-cdp-profile"`), `test_DW_2_3_no_label_for_default_dir`, `test_DW_2_3_no_label_when_nil`, `test_DW_2_3_enrich_appends_dir_basename_to_subtitle` (enrich → subtitle `"Default · chrome-cdp-profile"`) |
| DW-2.4 | Two instances sharing a profile display name → distinct `stableID`s | COVERED | `test_DW_2_4_distinct_stable_ids_for_same_profile_diff_dir` (two `enrich` calls, same title, different `userDataDir` → different `stableIDSuffix`) |

**All items COVERED:** YES (4 DW-IDs in prompt == 4 rows here)

## Design Decisions

**Pure helper: `ChromeInstancePolicy` (new `Picker/Enrichment/ChromeInstancePolicy.swift`).**

```swift
enum ChromeInstancePolicy {
    // DW-2.1: extract --user-data-dir from an argv array.
    // Handles --user-data-dir=/path and --user-data-dir /path. nil if absent.
    static func extractUserDataDir(argv: [String]) -> String?

    // DW-2.3: map a user-data-dir to a picker label.
    // nil for absent (caller passes nil) or the default Chrome dir; else basename.
    static func instanceLabel(forUserDataDir dir: String?, defaultDataDir: String) -> String?

    // Production convenience: resolves the real default Chrome data dir.
    static func defaultChromeDataDir() -> String
}
```

- `extractUserDataDir`: scan argv; for each arg, if it starts with `--user-data-dir=` return the suffix; if it equals `--user-data-dir` return the next element (or nil if last). Empty value → treated as absent (nil) defensively.
- `instanceLabel`: nil-in → nil. Standardize both paths (`(dir as NSString).standardizingPath`, strip trailing `/`); equal to default → nil; else `(dir as NSString).lastPathComponent`. Empty basename → nil (defensive).

**Impure boundary: `ProcessArgsReader` (new `Picker/Enrichment/ProcessArgsReader.swift`).**

A small class owning a per-PID cache. `userDataDir(forPID:) -> String?`:
1. Cache hit → return cached (cache stores `String??` so a resolved-nil is not re-read every call).
2. `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` with NULL `oldp` to size, then allocate, then read.
3. Parse argc (first `Int32`), skip exec path, skip NUL padding, read exactly `argc` NUL-terminated args, every read bounded to the `oldlenp` length the syscall returned. Any boundary/decode failure → `nil`.
4. `extractUserDataDir(argv:)` on the parsed args.
5. On syscall error / truncated buffer / undecodable bytes → `nil`, and `jlog("err.chrome.procargs", ...)` **once** (guarded by a `loggedFailure` flag so it does not spam every picker open). Cache the nil so repeated reads stay quiet and cheap.

This is the barricade: the syscall buffer is untrusted external input (GC-1) — every offset is bounds-checked against the returned length before reading; no read past `oldlenp`; failure returns a typed nil rather than crashing (RF-12 — the nil is distinguishable as "no label", and the failure is logged, not silently masked).

**`ChromeEnricher` widening (seam contract):**
`enrich(windowTitle: String, userDataDir: String? = nil) -> EnrichmentResult?`. After computing the existing `subtitle` / `profileLabel`:
- `let dirLabel = ChromeInstancePolicy.instanceLabel(forUserDataDir: userDataDir, defaultDataDir: ChromeInstancePolicy.defaultChromeDataDir())`
- If `dirLabel != nil`: append `" · \(dirLabel!)"` to the subtitle (subtitle may have been empty for a bare "Default" with no metadata → becomes `"Default · chrome-cdp-profile"` by prefixing the `profileLabel` when subtitle is empty), and append `"@\(dirLabel!)"` (or `":\(dirLabel!)"`) to the `stableIDSuffix` so two same-profile instances diverge (DW-2.4).
- Default instance (`dirLabel == nil`): subtitle and stableID unchanged (DW-2.3 "no label").

Concretely for the CDP case (Branch 2, no Local State default name): `profileLabel = "Default"`, base subtitle `""`. With a dir label the subtitle becomes `"Default · chrome-cdp-profile"` and `stableIDSuffix` becomes `"chrome:Default@chrome-cdp-profile"` (was `"chrome:Default"`). A second instance `/tmp/chrome-cdp-profile-2` → `"chrome:Default@chrome-cdp-profile-2"`. Distinct (DW-2.4).

**`WindowEnricher` widening:**
`enrich(bundleID:pid:title:axTitle:userDataDir:)` — passes `userDataDir` straight to `chromeEnricher.enrich`. Owns a `ProcessArgsReader` and exposes nothing else (kept as the single registry entry point). Decision: resolve the dir inside `WindowEnricher.enrich` itself (it already has `pid`), so `WindowSource` needs no new wiring beyond it already calling `enrich`. The reader lives on `WindowEnricher` (session-scoped, cache survives the discovery loop; the registry is rebuilt per `PickerManager` session so PID cache staleness is naturally bounded).

**Defensive-programming (cc-defensive-programming):**
- GC-1 / barricade: `KERN_PROCARGS2` buffer is external input — validated at the `ProcessArgsReader` boundary (bounds-check every offset against returned length); pure helpers inside assume a clean argv array.
- RF-12 (fallback masking failure): the nil on failure is the legitimate "default instance, no label" value AND the failure is logged once — distinguishable, not silently swallowed.
- SO-2 (check return codes): `sysctl` return value checked on both the sizing and the fetch call; non-zero → nil.
- No empty catch, no executable code in assertions, no assertions for runtime/external conditions. Pure helpers are side-effect-free.
- Path handling: basename via `NSString.lastPathComponent` (no shell, no concatenation) — no command/path-traversal surface (SM-1/SM-3 N/A but clean).

## Prerequisites

- [x] Phase 1 committed (seam left single-arg, `userDataDir: String? = nil` default keeps call sites valid)
- [x] `ChromeEnricher` Branch 2 (bare "Default") is where CDP instances land — confirmed
- [x] `generateStableID` `.chrome` branch returns suffix verbatim — folding dir into suffix suffices for DW-2.4
- [x] `EventAllowlistTests` is the gate for the new `err.chrome.procargs` event — will register it

## Live verification handoff (for orchestrator)

The worktree build cannot drive the live picker UI. After `make run` on the running server, the orchestrator confirms DW-2.3 live by:
1. Confirm the two CDP instances are running and read their dirs:
   `ps -Ao pid,command | grep -i 'chrome.*user-data-dir' | grep -E '/tmp/chrome-cdp-profile'`
   — expect PIDs whose args carry `--user-data-dir=/tmp/chrome-cdp-profile` and `--user-data-dir=/tmp/chrome-cdp-profile-2`.
2. Open the picker (`mcp__thegrid__pick_show` or the bound hotkey) and inspect the two CDP entries' subtitles — expect `Default · chrome-cdp-profile` and `Default · chrome-cdp-profile-2`; the real multi-profile Chrome entries (Ryan / Omniping / Victoria and Ryan) show NO `· <dir>` label.
3. Confirm distinct picker IDs (DW-2.4): the two CDP entries both appear (not deduped into one) — dedup is by stableID, so two rows means distinct IDs.
4. If a `KERN_PROCARGS2` read failed: `grep '"ev":"err.chrome.procargs"' ~/.local/state/thegrid/thegrid-server.json | tail` — should be empty in the normal case; at most one entry if a PID died mid-read.

## Recommendation

BUILD. Pure helpers + a thin bounded syscall reader + a one-line widening of the existing single profile-resolution seam. No plan deviation, no new scope. The default `userDataDir: String? = nil` keeps every existing call site valid.
