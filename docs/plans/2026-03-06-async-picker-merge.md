# Plan: Async-First Picker — Merge into Server

**Created:** 2026-03-06
**Status:** ready

## Context

The grid picker has a fundamental design flaw: all data work (RPC fetch, enrichment, source discovery, history sorting) happens sequentially in the Go CLI **before** the picker window appears. The hotkey-to-window latency is 200-400ms (shell spawn + Go boot + RPC + enrichment + picker IPC).

This plan merges the picker directly into the server process, eliminating all IPC. BFD (already in-process) triggers the picker directly. Window appears in <50ms. Data streams in asynchronously.

**Key architectural decisions:**
- Merge picker INTO server (eliminate standalone `grid-picker` binary)
- Port ALL enrichment + source discovery from Go to Swift
- Server manages history/frecency
- Single unified picker (no separate `pick window` vs `pick` commands)
- BFD `@pick` directive for zero-latency hotkey trigger
- CLI `thegrid pick` still works via RPC (for scripting)
- Append + re-filter when items stream in (preserve typed query + selection)
- Subtle spinner while loading

## Chosen Approach: PickerManager Class (Protocol-Based Sources)

Single `PickerManager` class on main thread owns the picker window lifecycle. `PickerSource` protocol — each source implements `discover() async -> [PickerItem]`. Sources run in parallel via `TaskGroup`, items stream to UI as each completes.

Follows existing `SimpleBorderManager` pattern (main-queue class managing NSWindows).

```
BFD hotkey (main thread)
  -> PickerManager.shared.show()
    -> show window immediately (<1ms)
    -> Task { discoverAndStream() }
      -> TaskGroup:
        WindowSource  -> items -> MainActor appendItems()
        AppSource     -> items -> MainActor appendItems()
        ZoxideSource  -> items -> MainActor appendItems()
        ChromeSource  -> items -> MainActor appendItems()
        ActionSource  -> items -> MainActor appendItems()
```

## Implementation Checklist

### Phase 1: Picker UI in Server + Window Source

Move picker UI into server, show window via BFD, display windows from StateManager.

- [ ] Create `Sources/GridServer/Picker/` directory
- [ ] Port picker UI from `Sources/GridPicker/main.swift` into separate files:
  - [ ] `PickerModels.swift` — `PickerItem`, `PickerResult`, `MatchResult`, `PickerConfig`
  - [ ] `FuzzyMatcher.swift` — `FuzzyMatcher` enum (scoring algorithm, unchanged)
  - [ ] `PickerState.swift` — `PickerState` class (query, filtered results, selection tracking)
  - [ ] `PickerViews.swift` — `BackgroundView`, `ListView`, `ListItemView`, `IconRenderer`, `Colors`, `Fonts`, `NSLabel`
  - [ ] `PickerWindow.swift` — `PickerWindow` class (NSWindow subclass, text field, key handling)
- [ ] Create `PickerManager.swift`:
  - [ ] Singleton class, main-thread only
  - [ ] Owns `PickerWindow` (created once, reused)
  - [ ] `show()` — switch activation policy `.prohibited` -> `.regular`, show window, focus input, start discovery Task
  - [ ] `hide()` — hide window, switch back to `.prohibited`
  - [ ] `appendItems([PickerItem])` — merge into state, dedup by ID, re-filter against current query, preserve selection
  - [ ] Spinner: show on `show()`, hide when all sources complete
  - [ ] Handle selection -> execute action + hide
  - [ ] Handle cancel (Esc / focus loss) -> cancel discovery Task + hide
- [ ] Create `PickerSource.swift` — protocol:
  ```swift
  protocol PickerSource {
      var id: String { get }
      func discover() async throws -> [PickerItem]
  }
  ```
- [ ] Create `WindowSource.swift`:
  - [ ] Read windows from `StateManager.shared` directly (no RPC)
  - [ ] Read cell assignments from runtime state (`state.json`)
  - [ ] Filter to cell-assigned windows
  - [ ] Build PickerItems with `bundle:{bundleID}` icons
  - [ ] No enrichment yet (Phase 2)
- [ ] Wire BFD `@pick` directive:
  - [ ] In `BFDKeyHandler.swift` or `BFDManager.swift`: detect commands starting with `@`
  - [ ] `@pick` -> `DispatchQueue.main.async { PickerManager.shared.show() }`
  - [ ] Skip `BFDExecutor` for `@` commands (no shell)
- [ ] Wire selection action: focus window via existing `WindowManipulator` + border sync
- [ ] Update `bfd.yaml` example: `ctrl-p: @pick`
- [ ] Handle activation policy transitions:
  - [ ] Guard against transient `windowDidResignKey` during policy switch
  - [ ] Center window on mouse-cursor screen (`NSScreen.screens.first(where: NSMouseInRect)`)

**Files to modify:**
- `grid-server/Sources/GridServer/BFD/BFDManager.swift` — intercept `@` directives
- `grid-server/Sources/GridServer/BFD/BFDKeyHandler.swift` — route `@pick` to PickerManager

**Files to create:**
- `grid-server/Sources/GridServer/Picker/PickerModels.swift`
- `grid-server/Sources/GridServer/Picker/FuzzyMatcher.swift`
- `grid-server/Sources/GridServer/Picker/PickerState.swift`
- `grid-server/Sources/GridServer/Picker/PickerViews.swift`
- `grid-server/Sources/GridServer/Picker/PickerWindow.swift`
- `grid-server/Sources/GridServer/Picker/PickerManager.swift`
- `grid-server/Sources/GridServer/Picker/PickerSource.swift`
- `grid-server/Sources/GridServer/Picker/WindowSource.swift`

**Verification:** Press `ctrl-p` -> picker window appears instantly, shows cell-assigned windows (no enrichment), selecting a window focuses it.

---

### Phase 2: Enrichment + History

Port terminal enrichers (tmux, SSH, Chrome) and frecency history to Swift.

- [ ] Create `Picker/Enrichment/` directory
- [ ] Port process tree utilities:
  - [ ] `ProcessTree.swift` — `getDescendantPIDs(parentPID:, maxDepth:) -> [pid_t]`
  - [ ] Uses `sysctl` for parent PID lookup (or `ps -eo pid,ppid` for batch)
  - [ ] Build tree once per discovery session, depth-limited BFS
- [ ] Port `TmuxEnricher.swift`:
  - [ ] `tmux list-clients -F "#{client_pid}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}"`
  - [ ] `tmux list-windows -t {session} -F "#{window_name}"`
  - [ ] Cache: `~/.local/state/thegrid/tmux-cache.json` (windowPID -> clientPID mapping)
  - [ ] Descendant search depth: 4
- [ ] Port `SSHEnricher.swift`:
  - [ ] `ps -ax -o pid=,comm=` for SSH process cache
  - [ ] `ps -o args= -p {pid}` for SSH command line
  - [ ] SSH args flag parser (`-l`, `-p`, `-i`, etc.)
  - [ ] Descendant search depth: 6
  - [ ] Title context parsing: `~path: command` format
- [ ] Port `ChromeEnricher.swift`:
  - [ ] Read `~/Library/Application Support/Google/Chrome/Local State`
  - [ ] Regex: `- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$`
  - [ ] Profile name resolution: name -> gaiaName -> userName -> profileDir
- [ ] Create `WindowEnricher.swift` — registry combining all three enrichers:
  - [ ] `refreshCaches()` — single batch of subprocess calls
  - [ ] `enrich(bundleID:, pid:, title:) -> EnrichmentResult?`
  - [ ] `cleanup()` — persist caches
  - [ ] SSH only supports `com.mitchellh.ghostty`
- [ ] Update `WindowSource.swift` to use `WindowEnricher`
- [ ] Port `PickerHistory.swift`:
  - [ ] File: `~/.local/state/thegrid/picker-history.json`
  - [ ] Schema: `{version, previous, frequency: {id: count}, lastPicked: {id: timestamp}}`
  - [ ] `recordSelection(id)` — update previous, frequency, lastPicked
  - [ ] Max 100 entries (prune by lastPicked LRU)
  - [ ] Load on server start, save on selection
- [ ] Port frecency scoring:
  - [ ] `frecencyScore(id) = frequency * (1.0 / (1.0 + hoursSince / 24.0))`
  - [ ] Source boost multipliers: windows=10, apps=1, chrome=1, actions=1.5, zoxide=0.5
  - [ ] `finalScore = max(frecency, 1.0) * sourceBoost`
  - [ ] Stable sort by finalScore descending
- [ ] Port stable window ID generation:
  - [ ] tmux: `tmux:{session}:{window}`
  - [ ] SSH: `ssh:{user}@{host}` or `ssh:{user}@{host}/{session}:{window}`
  - [ ] Bundle: `{bundleID}:{normalizedTitle}:{hash4}`
  - [ ] `normalizeTitle`: lowercase -> replace `[^a-z0-9]+` with `-` -> trim -> truncate 30 -> trim
  - [ ] `hash4`: SHA256 -> hex -> first 4 chars
- [ ] Wire history into `PickerManager`: sort items by frecency after each source batch

**Files to create:**
- `grid-server/Sources/GridServer/Picker/Enrichment/ProcessTree.swift`
- `grid-server/Sources/GridServer/Picker/Enrichment/TmuxEnricher.swift`
- `grid-server/Sources/GridServer/Picker/Enrichment/SSHEnricher.swift`
- `grid-server/Sources/GridServer/Picker/Enrichment/ChromeEnricher.swift`
- `grid-server/Sources/GridServer/Picker/Enrichment/WindowEnricher.swift`
- `grid-server/Sources/GridServer/Picker/PickerHistory.swift`

**Files to modify:**
- `grid-server/Sources/GridServer/Picker/WindowSource.swift` — add enrichment
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` — add history + frecency sort

**Verification:** Picker shows enriched window titles (tmux session names, SSH hosts). History sorts recently-used items to top. Selecting records history.

---

### Phase 3: All Sources (Apps, Zoxide, Chrome Profiles, Actions)

- [ ] Create `Picker/Sources/AppSource.swift`:
  - [ ] Scan `/Applications`, `/System/Applications`, `~/Applications`
  - [ ] Read `Info.plist` for CFBundleIdentifier, CFBundleName, CFBundleDisplayName
  - [ ] Dedup by bundleID
  - [ ] Action: `open -na "{appPath}"`
- [ ] Create `Picker/Sources/ZoxideSource.swift`:
  - [ ] Find zoxide binary: config override -> PATH -> `~/.cargo/bin` -> `/opt/homebrew/bin` -> `/usr/local/bin`
  - [ ] Run `{zoxide} query -l`
  - [ ] Title: basename, Subtitle: display path with ~ substitution
  - [ ] Action: open tmux session in Ghostty (sanitize name, `tmux has-session` / `new-session`, `open -na Ghostty`)
- [ ] Create `Picker/Sources/ChromeProfileSource.swift`:
  - [ ] Read `~/Library/Application Support/Google/Chrome/Local State`
  - [ ] Parse `profile.info_cache` for display names
  - [ ] Action: `open -na "Google Chrome" --args --profile-directory="{dir}"`
- [ ] Create `Picker/Sources/ActionSource.swift`:
  - [ ] Read from server config (already loaded)
  - [ ] ID: `action:{slug}` (name -> lowercase, spaces -> hyphens)
  - [ ] Action: shell out `sh -c "{command}"` with clean env (no TMUX vars)
- [ ] Create `Picker/ActionExecutor.swift`:
  - [ ] `executeAction(_ action: PickerAction)` — route by type
  - [ ] Types: `focus-window` (via WindowManipulator), `open-app`, `open-chrome-profile`, `exec`, `open-dir`
  - [ ] Clean env: strip TMUX, TMUX_PANE, TMUX_PLUGIN_MANAGER_PATH
- [ ] Register all sources in `PickerManager`:
  - [ ] `sources: [PickerSource]` initialized with all 5 sources
  - [ ] Source config from server config (actions list, zoxide path, enabled flags)
- [ ] Add spinner to PickerWindow:
  - [ ] Small `NSProgressIndicator` (spinning style) in the prompt area
  - [ ] Show on `show()`, hide when `discoverAndStream()` completes
- [ ] Source priority on PickerItems:
  - [ ] Windows: priority 1000, Apps: 100, Chrome: 100, Actions: 150, Zoxide: 50

**Files to create:**
- `grid-server/Sources/GridServer/Picker/Sources/AppSource.swift`
- `grid-server/Sources/GridServer/Picker/Sources/ZoxideSource.swift`
- `grid-server/Sources/GridServer/Picker/Sources/ChromeProfileSource.swift`
- `grid-server/Sources/GridServer/Picker/Sources/ActionSource.swift`
- `grid-server/Sources/GridServer/Picker/ActionExecutor.swift`

**Files to modify:**
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` — register sources, spinner
- `grid-server/Sources/GridServer/Picker/PickerWindow.swift` — spinner UI
- `grid-server/Sources/GridServer/ServerConfig.swift` — picker source config (if needed)

**Verification:** Picker shows windows, apps, Chrome profiles, zoxide dirs, and custom actions. Items appear progressively (windows first, then apps, etc.). Selecting an app opens it, selecting a dir opens Ghostty with tmux.

---

### Phase 4: CLI RPC + Cleanup

- [ ] Add `pick.show` RPC handler in `MessageHandler.swift`:
  - [ ] Triggers `PickerManager.shared.show()` on main thread
  - [ ] Blocks (via continuation) until user selects or cancels
  - [ ] Returns selected item JSON (or cancelled flag)
- [ ] Update CLI `thegrid pick` command:
  - [ ] Send `pick.show` RPC to server
  - [ ] Print result for scripting
  - [ ] Remove ALL Go-side picker orchestration (enrichment, sources, history, launchPicker)
- [ ] Remove `pick window` subcommand (unified picker only)
- [ ] Remove standalone grid-picker:
  - [ ] Delete `Sources/GridPicker/` directory
  - [ ] Remove `GridPicker` target from `Package.swift`
  - [ ] Remove `grid-picker` from `Makefile` / distribution pipeline
- [ ] Remove Go-side picker code:
  - [ ] Remove `grid-cli/internal/enrichers/` package
  - [ ] Remove `grid-cli/internal/sources/` package (keep if used elsewhere)
  - [ ] Remove `grid-cli/internal/state/picker_history.go`
  - [ ] Remove picker functions from `grid-cli/cmd/grid/main.go` (runPickWindow, runUnifiedPick, launchPicker, tryPickerSocket, spawnPickerDaemon, windowsToPickerItems, stableWindowID, sortItemsByHistory, convertSourceItemsToPickerItems, etc.)
- [ ] Update BFD default config to use `@pick` instead of `${grid} pick`
- [ ] Kill running grid-picker daemon on server start (like grid-terminal cleanup)

**Files to modify:**
- `grid-server/Sources/GridServer/MessageHandler.swift` — add `pick.show` handler
- `grid-server/Sources/GridServer/main.swift` — kill stale grid-picker on start
- `grid-server/Package.swift` — remove GridPicker target
- `grid-cli/cmd/grid/main.go` — slim down pick command to RPC-only
- `Makefile` — remove grid-picker from build/install

**Files to delete:**
- `grid-server/Sources/GridPicker/main.swift`
- Go enricher/source files (if confirmed unused elsewhere)

**Verification:** `thegrid pick` via CLI still works (sends RPC). Hotkey via BFD still works (direct). No grid-picker process running. Clean build with no warnings.

## Edge Cases

- **Selection during loading:** Works immediately with whatever is highlighted. Discovery Task cancelled, results discarded.
- **Activation policy race:** Set `.regular` BEFORE showing window. Guard `windowDidResignKey` with a short grace period after show to avoid transient dismiss.
- **Duplicate items:** Dedup by `item.id` with Set lookup. First source to provide an ID wins (windows arrive first).
- **Multi-monitor:** Center on mouse-cursor screen via `NSMouseInRect`. Fallback to `NSScreen.main`.
- **Empty state:** If no sources return items, show "No items found" in empty label (existing behavior).

## Test Coverage

**Level:** Per-phase, minimal unit tests for core logic only

## Test Plan

- [ ] Unit: FuzzyMatcher scoring (port existing picker_test.go test cases)
- [ ] Unit: Frecency scoring calculation
- [ ] Unit: Stable window ID generation
- [ ] Unit: Title normalization
- [ ] Manual: Hotkey -> window appears < 50ms (perceived)
- [ ] Manual: Type query before items load -> results filter correctly when they arrive
- [ ] Manual: Select item while sources still loading -> action executes
- [ ] Manual: Multi-monitor -> picker on correct screen
- [ ] Manual: `thegrid pick` via CLI -> works via RPC

## Notes

- Subprocess calls (tmux, ps, zoxide) should run on global dispatch queue, not cooperative thread pool
- The picker window is created once and reused across invocations (reset state on each show)
- Server activation policy must return to `.prohibited` after picker hides to stay out of Dock
- Source discovery is fire-and-forget per session — if user dismisses, Task is cancelled
- BFD `@` prefix is a general mechanism (could support `@terminal` etc. later, but YAGNI for now)

## Execution Log

_Filled during /code-foundations:building_
