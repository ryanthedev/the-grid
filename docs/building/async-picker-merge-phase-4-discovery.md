# Discovery: Phase 4 - CLI RPC + Cleanup

## Files Found

### Server-side (to modify)
- `grid-server/Sources/GridServer/MessageHandler.swift` -- RPC handler registration; uses callback-based `RequestHandler` pattern (`(Request, @escaping (Response) -> Void) -> Void`); handlers registered in `registerBuiltInHandlers()`
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` -- singleton, `show()` triggers async discovery; `handleResult(_ result: PickerResult)` is called by `PickerWindow.onResult` callback; currently `handleResult` is fire-and-forget (no continuation)
- `grid-server/Sources/GridServer/Picker/PickerModels.swift` -- `PickerResult` enum: `.selected(PickerItem)` or `.cancelled`; `PickerItem` is `Codable`
- `grid-server/Sources/GridServer/main.swift` -- server startup; has kill pattern for `grid-terminal` (lines 46-50) to reuse for `grid-picker`
- `grid-server/Package.swift` -- has `GridPicker` target (lines 60-64), product (lines 17-19)

### Server-side (to delete)
- `grid-server/Sources/GridPicker/main.swift` -- standalone picker binary (~1929 lines), fully superseded by in-server picker

### CLI-side (to modify)
- `grid-cli/cmd/grid/main.go` -- contains all picker orchestration:
  - Lines 2111-2116: `pickCmd` command definition
  - Lines 2119-2126: `pickWindowCmd` subcommand definition
  - Lines 2128-2152: `PickerItem`, `PickerResult`, `PickerContext` types
  - Lines 2156-2207: `findPickerExecutable()`
  - Lines 2210-2312: `pickerSocketPath()`, `tryPickerSocket()`, `spawnPickerDaemon()`, `waitForPickerSocket()`, `launchPicker()`
  - Lines 2331-2452: `windowsToPickerItems()`, `normalizeTitle()`, `hash4()`
  - Lines 2454-2487: `stableWindowID()`
  - Lines 2488-2513: `sortItemsByHistory()`
  - Lines 2515-2679: `runPickWindow()`
  - Lines 2681-2799: `runUnifiedPick()`
  - Lines 2801-2857: `resolveEnabledSources()`
  - Lines 2859-2939: `discoverWindowsAsSourceItems()`
  - Lines 2941-2983: `convertSourceItemsToPickerItems()`
  - Lines 2985-3000: `parseActionFromMetadata()`
  - Lines 3002-3039: `handleWindowFocus()`
  - Lines 3041-3178: `handleOpenDir()`
  - Lines 5075-5079: command registration (`pickCmd`, `pickWindowCmd`, flags)
  - Lines 5250-5251: `shouldSkipMutex` entries for pick commands
  - Imports: `enrichers` (line 42), `sources` (line 35)

### CLI-side (to delete)
- `grid-cli/internal/sources/` -- 9 files (actions.go, apps.go, chrome.go, executor.go, executor_test.go, sources.go, sources_test.go, types.go, zoxide.go)
- `grid-cli/internal/state/picker_history.go` -- PickerHistory, FrecencyScore, SortByFrecency, SourceBoosts
- `grid-cli/internal/state/picker_history_test.go`
- `grid-cli/cmd/grid/picker_test.go` -- tests for stableWindowID, normalizeTitle, hash4

### CLI-side (to keep - NOT picker-only)
- `grid-cli/internal/enrichers/` -- 10 files; ALSO used by `edit` command (line 1585: `enrichers.NewRegistry()`) for window title enrichment in layout editing. CANNOT DELETE.

### Build system (to modify)
- `Makefile` -- has `picker` target (line 39-41), `picker-universal` (lines 131-140), `dev` depends on `picker` (line 240), `install-dev` copies grid-picker (lines 269-276), `dist-universal` depends on `picker-universal` (line 172) and copies grid-picker (lines 178, 194)

### Config (to modify)
- `grid-cli/internal/config/types.go` -- `Settings.PickerPath` field (line 40)
- `grid-cli/internal/config/config.go` -- `ExpandPaths()` expands PickerPath (line 378)
- `grid-cli/internal/config/config_test.go` -- tests PickerPath expansion (lines 810-831)
- BFD config: No `bfd.yaml` checked into repo. The `@pick` directive is already handled in `BFDManager.swift` (line 113). User's local config would already use `@pick` if they followed Phase 1 guidance.

## Current State

Phases 1-3 are fully implemented. The in-server picker is complete with:
- All 5 sources (Windows, Apps, Chrome Profiles, Zoxide, Actions)
- Enrichment (tmux, SSH, Chrome) ported to Swift
- Frecency history in Swift
- BFD `@pick` directive working
- PickerManager handles show/hide/result lifecycle

The Go CLI `thegrid pick` and `thegrid pick window` commands still contain all the old orchestration code -- they launch the standalone `grid-picker` daemon, do enrichment in Go, manage history in Go, etc. This code is fully superseded.

## Gaps

### Gap 1: PickerManager has no continuation support for RPC
The `handleResult` method is fire-and-forget: it hides the picker and executes the action. For the `pick.show` RPC handler, we need a way to:
1. Call `show()` on main thread
2. Block (via async continuation) until the user selects or cancels
3. Return the `PickerResult` to the RPC handler
4. The RPC handler then converts it to a Response and calls `completion()`

The current `PickerWindow.onResult` callback fires into `PickerManager.handleResult()` which immediately executes the action. For RPC mode, the action should NOT be executed server-side -- the CLI caller just wants the selection result returned.

### Gap 2: enrichers package is used by `edit` command
The plan says "Remove `grid-cli/internal/enrichers/` package" but the `edit` command (layout editing) uses `enrichers.NewRegistry()` at line 1585. The enrichers package MUST be kept.

### Gap 3: `sources.ExecuteAction` used by `handleOpenDir`
`handleOpenDir` (line 3071) calls `sources.ExecuteAction()` for the `open-dir` action type. Since `handleOpenDir` is only called from `runUnifiedPick` (being removed), this is fine -- `handleOpenDir` itself gets removed too.

### Gap 4: PickerPath config field becomes dead code
`Settings.PickerPath` in the Go config is only used for `launchPicker()` calls. Once removed, the field and its path expansion should be cleaned up.

### Gap 5: gridState picker functions used by non-picker code
`gridState.LoadState()` is heavily used throughout main.go (non-picker). The state package must be kept. Only `picker_history.go` and its test should be removed. The `SortByFrecency`, `DefaultSourceBoosts`, `SourceBoosts` types are only used by picker code in main.go.

## Prerequisites

- [x] Phases 1-3 implemented (picker functional in server)
- [x] MessageHandler RPC pattern understood (callback-based)
- [x] PickerManager lifecycle understood
- [x] Import dependencies mapped (enrichers kept, sources removed)
- [x] Build system targets identified
- [ ] Need to design continuation mechanism for RPC -> PickerManager

## Recommendation

**BUILD** -- This phase is the final cleanup. All functional dependencies are met. The key design decision is how to add continuation support to PickerManager for the RPC path. Two approaches exist:
1. Add an optional continuation stored in PickerManager that, when present, skips action execution and instead resumes with the result
2. Add a separate `showAndWait()` async method that uses `withCheckedContinuation`

The second approach is cleaner (does not modify existing `show()` behavior for BFD).
