# Review: Phase 3 - All Sources (Apps, Zoxide, Chrome Profiles, Actions)

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies "Per-phase, minimal unit tests for core logic only" -- Phase 3 is data sources + executor, no new algorithmic logic requiring unit tests)

### Section-by-Section Mapping

| Pseudocode Section | Implementation File | Status |
|---|---|---|
| ServerConfig.swift (PickerSourceConfig + ActionDef) | ServerConfig.swift:1-25 | MATCH -- `ActionDef` struct with name/command/category/icon, `PickerSourceConfig` with actions array and zoxidePath, CodingKeys with snake_case, `builtinDefaults()` includes picker |
| PickerModels.swift (PickerAction new cases) | PickerModels.swift:136-168 | MATCH -- all 5 cases present (focusWindow, openApp, openChromeProfile, exec, openDir), `from(metadata:)` parser handles all 5 with correct key lookups |
| AppSource.swift | Sources/AppSource.swift | MATCH -- scans 3 dirs, dedup by bundleID via Set, PropertyListSerialization for plist, display name priority (DisplayName > BundleName > filename), priority=100, correct metadata keys, sorted by title |
| ZoxideSource.swift | Sources/ZoxideSource.swift | MATCH -- configuredPath injection, findZoxide() checks config override then 3 absolute paths, `zoxide query -l`, tilde substitution, basename title, priority=50, correct metadata |
| ChromeProfileSource.swift | Sources/ChromeProfileSource.swift | MATCH -- reads Local State JSON, parses profile.info_cache, name priority chain (name if not default > gaiaName > shortcutName > userName > profileDir), searchable includes "chrome"/"browser" + additional names, priority=100 |
| ActionSource.swift | Sources/ActionSource.swift | MATCH -- reads ActionDef array, skips empty name/command, slug generation (lowercase + space-to-hyphen), default icon "terminal", subtitle from category or "Action", searchable with individual words, priority=150 |
| ActionExecutor.swift | ActionExecutor.swift | MATCH -- stateless struct with static methods, 5-way switch routing, focusWindow uses WindowManipulator, openApp uses NSWorkspace, openChromeProfile spawns `open -na`, exec uses user shell, openDir does tmux create-or-attach + Ghostty launch |
| ActionExecutor helpers | ActionExecutor.swift:94-150 | MATCH -- userShell(), cleanEnvironment() strips 3 TMUX vars, sanitizeTmuxName() replaces dots and colons, findZoxideBinary() checks 3 paths, spawnDetached() runs on DispatchQueue.global() with error logging |
| PickerManager.swift changes | PickerManager.swift:30,43-46,165-179,153-159 | MATCH -- config property added, configure(with:) method, discoverAndStream builds 5 sources (conditional ActionSource), executeAction delegates to ActionExecutor.execute() |

### Priority Values Verified
- Windows: 1000 (set in WindowSource, not in Phase 3 scope)
- Apps: 100 (AppSource.swift:100)
- Chrome: 100 (ChromeProfileSource.swift:76)
- Actions: 150 (ActionSource.swift:62)
- Zoxide: 50 (ZoxideSource.swift:58)

## Dead Code
None found.
- All imports are used (Foundation for file/process operations, AppKit for NSWorkspace and SLSMainConnectionID in ActionExecutor)
- No commented-out blocks
- No debug statements
- No unreachable code after early returns
- `cleanEnvironment()` is used by `spawnDetached()` when `cleanEnv: true`

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 8 pseudocode sections mapped to implementation with correct behavior. All plan Phase 3 checklist items addressed: 4 source files, ActionExecutor, PickerManager wiring, ServerConfig, source priorities. |
| Concurrency | PASS | Sources run in TaskGroup (existing Phase 1/2 infrastructure). `spawnDetached()` dispatches to `DispatchQueue.global()` for Process() calls. `runProcess()` also dispatches to `DispatchQueue.global()`. `openDirInTmux` launches a Task for async tmux commands. Main-thread preconditions enforced via `dispatchPrecondition` in PickerManager. No shared mutable state across sources (each source is a value type with no mutation). |
| Error Handling | PASS | AppSource: `try?` on directory listing and plist parse -- missing dirs silently skipped. ZoxideSource: nil return from findZoxide handled (returns empty). ChromeProfileSource: missing file or bad JSON returns empty. ActionSource: skips entries with empty name/command. ActionExecutor: all subprocess errors logged via `jlog`. `spawnDetached` catch block logs errors. `openApp` completion handler logs errors. `openDirInTmux` uses nil checks on subprocess results. |
| Resource Mgmt | PASS | Process objects in `spawnDetached()` are fire-and-forget (stdout/stderr sent to nullDevice). No file handles leaked -- `FileManager.default.contents(atPath:)` returns Data directly. No persistent connections or locks acquired. |
| Boundaries | PASS | Empty input: all sources return `[]` when no data found. Missing tools: ZoxideSource returns empty if zoxide not installed. Missing Chrome: returns empty if Local State missing. Empty actions config: ActionSource skipped entirely (`!actions.isEmpty` guard). Empty name/command in ActionDef: skipped via guard. |
| Security | N/A | All input comes from local filesystem (Info.plist, Chrome Local State, server config YAML). No untrusted external input. `.exec` command comes from server config which is under user control. |

## Defensive Programming

### Crisis Invariants Checked
| Check | Status | Evidence |
|-------|--------|----------|
| No empty catch blocks | PASS | `spawnDetached()` catch block logs via `jlog("pick.exec.err", ...)`. TaskGroup catch block logs source errors. |
| External input validated | PASS | Plist keys checked for nil/empty. Chrome JSON parsed with fallback. ActionDef name/command validated non-empty. Zoxide config path checked for existence. |
| No executable code in assertions | PASS | No assertions with side effects. `dispatchPrecondition` is a development aid that does not contain business logic. |
| Errors match abstraction level | PASS | Source errors are caught at TaskGroup level and logged with source ID. ActionExecutor errors logged with executable path and error description. No implementation-detail exceptions leaked upward. |

### Barricade Design
- External data boundaries properly identified: filesystem reads (plist, Chrome JSON, zoxide output) all validated at point of entry with graceful empty returns.
- Inside the barricade (PickerItem construction), metadata keys are string constants -- type-safe within the system.

### Error Handling Strategy Consistency
- All sources follow the same pattern: missing tool/file returns empty array (robustness). Errors logged but not propagated (consumer app pattern, consistent with picker UI philosophy of "show what you can").
- ActionExecutor follows fire-and-forget with logging on failure (consistent with subprocess execution pattern established by `runProcess()`).

## Notes
- `configure(with:)` is called from `StateManager.swift:112`, confirming the wiring path exists.
- `PickerHistory.sourceBoost` already recognizes all source prefixes (app:, chrome:, action:, zoxide:) with correct multiplier values matching the plan.
- The spinner lifecycle is handled by existing Phase 1/2 code -- `setLoading(true)` on show, `setLoading(false)` when TaskGroup completes. No Phase 3 work needed.
- Build compiles clean with zero warnings.
