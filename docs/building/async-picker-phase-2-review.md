# Phase 2 Review: Enrichment + History

**Reviewer:** Post-gate automated review
**Date:** 2026-03-07
**Branch:** feature/grid-viewer

---

## Category Reviews

### 1. ProcessTree — PASS

**Checklist:**
- Uses `DispatchQueue.global()` for subprocess: YES — `withCheckedThrowingContinuation` wraps a `DispatchQueue.global().async` block, exactly as spec'd.
- BFS with depth limit: YES — iterative BFS using `(pid, depth)` queue with `guard depth < maxDepth else { continue }`.
- Caches tree: YES — caller (`WindowEnricher`) holds the tree instance per session; no global singleton (matches spec intent).

**Evidence:** `ProcessTree.swift` lines 27–90. `build()` returns an empty tree on error (non-fatal, matches spec). Parser skips header line via `dropFirst()`.

**No deviations.**

---

### 2. TmuxEnricher — PASS

**Checklist:**
- Runs `tmux list-clients` subprocess: YES — `runProcess(tmuxPath, args: ["list-clients", "-F", "..."])`.
- Parses pipe-delimited format: YES — `line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)`, 6 fields.
- Cache file at correct path: YES — `thegridStateDir + "/tmux-cache.json"` resolves to `~/.local/state/thegrid/tmux-cache.json`.
- Descendant search depth 4: YES — `tree.getDescendants(of: pid, maxDepth: 4)`.

**Minor deviation:** `runProcess` returns `String?` (nil on non-zero exit), but the pseudocode's `guard let output` also handles empty string explicitly. The implementation guards `!output.isEmpty` together, which is correct and slightly more defensive. Not a problem.

**Stable sort for `saveCache`:** Pseudocode says non-fatal on write failure; implementation logs `"tmux.cache.encode_err"` and falls through. Correct.

---

### 3. SSHEnricher — PASS

**Checklist:**
- Builds process cache from `ps -ax -o pid=,comm=`: YES — `runProcess("/bin/ps", args: ["-ax", "-o", "pid=,comm="])`.
- Descendant search depth 6: YES — `tree.getDescendants(of: pid, maxDepth: 6)`.
- Parses SSH args correctly: YES — handles `-l user host`, `user@host`, bare `host`. `flagsWithValues` set matches spec exactly (`-l, -p, -i, -o, -F, -J, -D, -L, -R, -W, -b, -c, -e, -m, -S, -w`). Falls back to `NSUserName()` when no user found.
- Only supports Ghostty: YES — `supportedBundleIDs = ["com.mitchellh.ghostty"]`.

**Minor deviation from pseudocode:** `parseSSHArgs` logs `"ssh.parse_err"` in `enrich()` when parse returns nil, which the pseudocode didn't specify — this is a defensive addition, appropriate and harmless.

---

### 4. ChromeEnricher — PASS

**Checklist:**
- Reads Local State JSON: YES — `~/Library/Application Support/Google/Chrome/Local State`, parsed with `JSONSerialization`.
- Regex matches profile name from title: YES — `#"- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$"#`. Capture group 1 extracts profile name.
- Lazy loads: YES — `private var loaded = false`; `loadLocalState()` called only on first `enrich()` call.

**Minor deviation:** The `supportedBundleIDs` is `["com.google.Chrome"]` only. The regex pattern includes Brave/Chromium/Edge but the `supports()` guard would prevent those from reaching `enrich()`. This is consistent with the pseudocode's spec comment ("only Chrome; other browsers use different Local State paths"). Not a bug.

**No enrichment for Default profile title stripping:** When no match (Default profile), title is returned as-is. Correct per pseudocode.

---

### 5. WindowEnricher — PASS

**Checklist:**
- Combines all three enrichers: YES — `tmuxEnricher`, `sshEnricher`, `chromeEnricher` all instantiated and called.
- Handles SSH+Tmux combo: YES — if both `sshResult` and `tmuxResult` are non-nil, combines with `kind: .sshAndTmux`, title from SSH, subtitle from tmux.
- Generates stable ID suffix: YES — delegated to `generateStableID()` in `WindowSource.swift`.
- Parallel cache refresh: YES — `async let tree = ProcessTree.build()`, `async let tmuxRefresh`, `async let sshRefresh`, all awaited together via tuple destructure.

**Minor deviation:** The pseudocode's `refreshCaches()` uses `async let _ = ...` for the two side-effect tasks. The implementation names them (`async let tmuxRefresh: Void`, `async let sshRefresh: Void`) and destructures as a 3-tuple. Semantically identical.

**Cleanup:** `cleanup()` calls `tmuxEnricher.saveCache()`. Correct.

---

### 6. PickerHistory — PASS

**Checklist:**
- Correct frecency formula: YES — `Double(freq) * (1.0 / (1.0 + hoursSince / 24.0))`. Exact match.
- Source boost multipliers match:
  - windows (all non-prefixed): 10.0 — YES
  - apps (`app:`): 1.0 — YES
  - chrome (`chrome:`): 1.0 — YES
  - actions (`action:`): 1.5 — YES
  - zoxide (`zoxide:`): 0.5 — YES
- Max 100 entries: YES — `static let maxEntries = 100`. Prune removes LRU by `lastPicked`.
- Atomic save: YES — write to `.tmp`, then `FileManager.moveItem`. Cleans up tmp on error.

**Stable sort implementation:** Pseudocode noted Swift's `sort` is not stable and recommended using enumerated indices. The implementation correctly uses `items.enumerated().map { ... }` followed by `sorted { ... }` with index as tiebreaker. This is the exact pattern the pseudocode suggested. PASS.

**File path:** `thegridStateDir + "/picker-history.json"`, resolves to `~/.local/state/thegrid/picker-history.json`. Correct.

**Validation on load:** Checks negative frequencies and timestamps, returns fresh history on any invalid entry. Matches spec.

---

### 7. WindowSource — PASS

**Checklist:**
- Uses enricher: YES — `await enricher.enrich(bundleID:pid:title:)` called per window.
- Generates stable IDs: YES — `generateStableID(wid:enrichment:bundleID:title:pid:)`.
- `normalizeTitle` correct: YES — lowercase → replace `[^a-z0-9]+` with `-` → trim hyphens → truncate 30 → trim trailing hyphen.
- `hash4` correct: YES — `SHA256.hash(data: Data(s.utf8))`, hex-encoded, `.prefix(4)`. Uses `CryptoKit` (imported at top of file).

**Subtitle nil-coalescing deviation:** The pseudocode has:
```
subtitle = e.subtitle
```
The implementation has:
```swift
subtitle = e.subtitle.isEmpty ? nil : e.subtitle
```
This is a minor improvement over the pseudocode (nil subtitle means no subtitle row in the UI vs. empty string subtitle). Appropriate and intentional.

**Searchable array:** Enriched title and subtitle added to searchable. Matches pseudocode.

---

### 8. PickerManager — PASS

**Checklist:**
- Loads history on init: YES — `history = PickerHistory.load()` in `private init()`, with `jlog("pick.hist.loaded", ...)`.
- Sorts by frecency: YES — `history.sortByFrecency(&allItems)` called after each source batch within `MainActor.run`.
- Records selection: YES — `history.recordSelection(item.id)` then `history.save()` in `handleResult(.selected)`.
- `allItems` reset on show: YES — `allItems = []` at start of `show()`.
- `WindowEnricher` created per session: YES — `let enricher = WindowEnricher()` inside `discoverAndStream()`.
- Uses `replaceItems` not `appendItems`: YES — `window.getState().replaceItems(allItems)`. `replaceItems` was added to `PickerState`.

---

### 9. Build — PASS

```
Build complete! (1.67s)
```

Zero errors, zero warnings.

---

## Issues Summary

| # | Severity | File | Description |
|---|----------|------|-------------|
| 1 | INFO | `WindowSource.swift` | `subtitle = e.subtitle.isEmpty ? nil : e.subtitle` — improvement over pseudocode's bare assignment; no issue |
| 2 | INFO | `SSHEnricher.swift` | `jlog("ssh.parse_err")` on parse failure — defensive addition not in pseudocode; appropriate |
| 3 | INFO | `ChromeEnricher.swift` | Regex includes Brave/Chromium/Edge but `supports()` only allows `com.google.Chrome` — intentional, harmless |

No FAIL-level issues found.

---

## Overall Verdict: PASS

All 9 categories pass. Build is clean. Implementation is a faithful translation of the pseudocode with only minor defensive improvements. Phase 2 is complete and correct.
