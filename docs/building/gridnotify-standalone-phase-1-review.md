# Review: Phase 1 - GridNotify Standalone App

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-1.1 | `grid-notify/` SPM package builds with `swift build` | SATISFIED | `swift build` completes with "Build complete!" (0.21s). Package.swift:1-27 matches spec: swift-tools-version 5.9, macOS(.v13), Yams 5.0.0 dep, executableTarget + testTarget. |
| DW-1.2 | GridNotify.app launches without grid-server running and displays the notification panel window | SATISFIED | AppDelegate.swift:14-81 creates NotificationStore, NotificationPanelViewModel, NotificationPanelWindow and calls `window.makeKeyAndOrderFront(nil)` with no dependency on grid-server sockets or processes. Info.plist sets `LSUIElement: false` (visible app). |
| DW-1.3 | Reads JSON lines from named pipe and displays notifications | SATISFIED | NotificationFileWatcher.swift:62-80 starts file/FIFO watcher; processLine:255-286 parses JSON via `NotificationLineDescriptor`; callback pattern (onNotification) triggers `vm.refreshNotifications()`. AppDelegate.swift:64-75 wires watcher. |
| DW-1.4 | Vim keybindings work (j/k navigate, d dismiss, p pin, / filter, V visual select) | SATISFIED | NotificationPanelViewModel.swift:271-376 handles all specified keys: j(38), k(40), d(2), p(35), /(44), V(9+shift). Visual select mode fully implemented at lines 198-243. |
| DW-1.5 | Notifications persist across app restarts (notifications.json) | SATISFIED | NotificationStore.swift: load():42-75 reads from `XDG.stateHome/thegrid/notifications.json`; persistNow():94-134 writes atomically via rename(). flush():137-141 called on terminate. testPersistAndReload passes. |
| DW-1.6 | YAML config loads theme colors and source paths | SATISFIED | NotifyConfig.swift:61-98 loads `XDG.configHome/thegrid/notify.yaml` via YAMLDecoder; maps `pipe.path`, `pipe.source_label`, `max_count`, `theme` dict. AppDelegate.swift:33-38 applies theme colors via `NotificationPanelTheme.init(from:)`. |
| DW-1.7 | Structured JSONL logging to thegrid-notify.json | SATISFIED | JSONLogger.swift:19 sets `filePath = "\(XDG.stateHome)/thegrid/thegrid-notify.json"`. jlog() free function at line 214 used throughout. AppDelegate logs `notify.start`, `notify.cfg.loaded`, `notify.store.ready`, `notify.ready`, `notify.shutdown`. |

**All requirements met:** YES

## Spec Match

- [x] All 17 pseudocode sections implemented (Package, DataModel, XDG, Logger, Store, FileWatcher, SourceConfig, Theme, ViewModel, Views, Window, Config, Info.plist, Entitlements, Version, AppLifecycle, Tests)
- [x] No unplanned additions (signal handler DispatchSource retain fix in AppDelegate is an implementation-level improvement of the pseudocode's signal handling, not a scope change)
- [x] Test coverage: all 5 pseudocode tests implemented and passing

Notable deviations from pseudocode (all minor, all improvements):

- AppDelegate retains `sigintSource` / `sigtermSource` as instance vars (pseudocode omitted this, it would have caused immediate deallocation — the implementation is correct)
- `applicationShouldHandleReopen` added for Dock icon re-show behavior — not in pseudocode but not a DW requirement, appropriate small addition
- `print("logging to \(JSONLogger.shared.getLogPath())")` at AppDelegate:20 — debug console output not in pseudocode; harmless but see Dead Code section

## Dead Code

One finding: `AppDelegate.swift:20` — `print("logging to \(JSONLogger.shared.getLogPath())")`. This is a debug convenience print statement that writes to stdout, not the JSONL log. It will appear in Console.app on every launch. Not a correctness issue but it leaks an internal path to stdout. Low severity — note as cleanup for Phase 2.

No other dead code, commented-out blocks, or unreachable code found across all files.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | NotificationStore is an `actor` — all mutations are serialized by the Swift runtime. NotificationFileWatcher uses a private serial `DispatchQueue` to protect `fd`, `readSource`, `fsSource`, `lineBuffer`, `isRunning`. JSONLogWriter uses its own serial queue. No shared mutable state crosses queue/actor boundaries without protection. |
| Error Handling | PASS | NotificationStore.load() catches decode errors and logs rather than crashing (line 71-74). persistNow() removes the .tmp file and re-marks dirty on write failure (lines 127-132). NotificationFileWatcher retries open() after 5 seconds on failure (lines 107-110). NotifyConfig falls back to defaults on missing file (line 65-68) and parse error (lines 91-97). JSONLogWriter.writeBatch silently swallows write errors (line 80-82) — intentional and documented ("logging should not crash the app"). |
| Resources | PASS | NotificationFileWatcher.tearDown():311-320 cancels both DispatchSources and closes fd. All reopen paths go through tearDown() first. JSONLogWriter opens a fresh FileHandle per batch and closes it via `defer { try? file.close() }` (line 71). NotificationStore atomic write uses a .tmp file that is cleaned up on failure. |
| Boundaries | PASS | Empty notifications list: `selectNext/Previous` guard on `notifications.isEmpty`. `currentNotification` guards `selectedIndex` bounds (ViewModel:192-194). `visualSelectedRange` uses `min/max` for correct direction-independent ranges. `trim()` guards `maxCount > 0` (Store:328). `notifications(filter:)` handles empty store correctly. Single-item list: `selectedIndex` clamped to `max(0, results.count - 1)` (ViewModel:71). |
| Security | PASS | `runShellCommand` uses `Process` with shell + `-c` (not string concatenation passed to system()). Path tilde expansion uses `FileManager.homeDirectoryForCurrentUser` not `$HOME` env var. No SQL. Pipe input is JSON-decoded into a typed struct before use — field values are strings, not executed. `focusWindow` windowID is UInt32, parsed with `UInt32($0)`, not used in any shell context. |

## Defensive Programming: PASS

Crisis triage (5 checks):

1. **External input validated at boundaries?** YES — pipe input parsed via JSONDecoder into `NotificationLineDescriptor`; unknown action types log and return nil; invalid JSON logs and skips the line.
2. **Return values checked for all external calls?** YES — `fstat()` return checked; `open()` return checked; `rename()` return checked; `Process.run()` throws are caught. One acceptable exception: `FileHandle.seekToEnd()` / `write()` errors are caught and swallowed in the log writer (intentional).
3. **Error paths tested?** Partially — tests cover the happy path and dismiss/filter paths. No test for corrupted notifications.json (load error path). Acceptable per the plan's "3-5 targeted tests" scope.
4. **Assertions on critical invariants?** N/A — no assertions present, which is appropriate for a consumer app; recoverable error handling is used throughout.
5. **Resources released on all paths?** YES — FileHandle closed via `defer`, fd closed in tearDown() which is called from all exit paths (stop, EOF reopen, fstat failure, rotation).

## Design Quality

**Depth finding (LOW severity):** `NotificationStore.bulkDismiss()` at lines 272-283 calls `notifications(filter:)` then iterates calling `dismiss()` individually. Each `dismiss()` calls `markDirty()`. For N notifications this schedules N debounced saves, but each cancels the previous, so only one save actually fires — correct but slightly wasteful. Not a correctness issue; the debounce absorbs it.

**Design is appropriately deep throughout.** NotificationFileWatcher hides all fd management, EOF reopening, and line buffering behind a `start()`/`stop()` interface. NotificationStore hides atomic writes, debouncing, and order validation. The callback pattern replacing `NotificationPanelManager.shared` is a clean decoupling.

**No unknown unknowns** — the code structure is clear and the change surface for future modifications is predictable.

**No pass-through methods** — each layer adds substantive behavior.

## Testing: PASS

| Test | Type | Covers |
|------|------|--------|
| testAddAndGet | clean | CRUD add + get + count |
| testDismissHidesFromActive | dirty (state mutation) | dismiss + filter behavior |
| testPersistAndReload | dirty (cross-instance) | atomic write + load |
| testPinSortsFirst | dirty (sort order) | pin sort invariant |
| testFilterBySearchText | dirty (query) | search filter predicate |

Ratio: 4 dirty : 1 clean = 4:1. Close to the 5:1 mature target. All 5 tests pass.

Coverage gap (acceptable for this plan scope): no test for load() with corrupted JSON, no test for trim(), no test for bulkDismiss(). These are lower-risk paths and the plan explicitly scoped to 3-5 tests.

## Issues

None blocking.

Minor (Phase 2 cleanup):
1. Debug print statement at AppDelegate.swift:20 — logs path to stdout on every launch. Remove or convert to `jlog()` only.
   - File: `grid-notify/Sources/GridNotify/AppDelegate.swift:20`
   - Fix: Remove the `print(...)` line; the same info is already in the JSONL log.

**Verdict: PASS**
