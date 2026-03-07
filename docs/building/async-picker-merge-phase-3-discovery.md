# Discovery: Phase 3 - All Sources (Apps, Zoxide, Chrome Profiles, Actions)

## Files Found

### Existing Picker infrastructure (from Phase 1 + 2)
- `grid-server/Sources/GridServer/Picker/PickerSource.swift` — protocol with `id` + `discover() async throws -> [PickerItem]`
- `grid-server/Sources/GridServer/Picker/WindowSource.swift` — reference implementation, uses enricher injection
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` — singleton, `discoverAndStream()` with TaskGroup, frecency sort
- `grid-server/Sources/GridServer/Picker/PickerWindow.swift` — already has spinner (`NSProgressIndicator`), `setLoading(bool)`
- `grid-server/Sources/GridServer/Picker/PickerModels.swift` — `PickerItem`, `PickerAction` enum (currently: `.focusWindow`, `.openApp`)
- `grid-server/Sources/GridServer/Picker/PickerHistory.swift` — frecency scoring, `sourceBoost` already recognizes `app:`, `chrome:`, `action:`, `zoxide:` prefixes
- `grid-server/Sources/GridServer/Picker/Enrichment/EnrichmentTypes.swift` — `runProcess()` subprocess helper, `findTmux()`, `thegridStateDir`
- `grid-server/Sources/GridServer/ServerConfig.swift` — currently only has `windowBlacklist` and `cliPath`

### Go reference implementations
- `grid-cli/internal/sources/apps.go` — `DiscoverApps()`, scans `/Applications`, `/System/Applications`, `~/Applications`, reads Info.plist
- `grid-cli/internal/sources/zoxide.go` — `findZoxideBinary()`, `DiscoverZoxide()`, runs `zoxide query -l`
- `grid-cli/internal/sources/chrome.go` — `DiscoverChromeProfiles()`, reads Chrome Local State JSON
- `grid-cli/internal/sources/actions.go` — `DiscoverActions()`, reads from config `ActionConfig` structs
- `grid-cli/internal/sources/executor.go` — `ExecuteAction()`, `cleanEnv()`, `openDirInTmux()`
- `grid-cli/internal/sources/types.go` — `SourceItem`, `Action` types
- `grid-cli/internal/config/types.go` — `PickerConfig`, `SourcesConfig`, `ActionConfig`, `ChromeConfig`

### Files to create (none exist yet)
- `grid-server/Sources/GridServer/Picker/Sources/` — directory does not exist
- `grid-server/Sources/GridServer/Picker/ActionExecutor.swift` — does not exist

## Current State

Phase 1 and 2 are fully implemented. The picker framework is operational:
- PickerSource protocol defined and working with WindowSource
- PickerManager runs sources via TaskGroup, streams items to UI, sorts by frecency
- Spinner already exists in PickerWindow (`NSProgressIndicator`, `setLoading(true/false)`)
- PickerHistory already has source boost multipliers for all planned source prefixes
- `runProcess()` helper exists for subprocess execution on DispatchQueue.global()
- `PickerAction` currently only handles `.focusWindow` and `.openApp`

The Go reference implementations provide complete, tested logic for all four new sources and the executor. These need porting to Swift, adapting to the existing PickerSource protocol pattern.

## Gaps

### 1. Sources/ subdirectory missing
The plan places new sources in `Picker/Sources/` — directory needs creating.

### 2. PickerAction needs new cases
Currently only `.focusWindow` and `.openApp`. Plan requires: `openChromeProfile`, `exec`, `openDir`. These need to be added to `PickerAction` enum and the `from(metadata:)` parser.

### 3. ServerConfig has no picker/actions config
The Go side has `PickerConfig` with `SourcesConfig` (enabled flags) and `ActionConfig[]`. The Swift `ServerConfig` has none of this. Need to decide: add picker config to ServerConfig, or hardcode all sources as enabled?

**Decision recommendation:** Add minimal config — `picker.actions` array for custom actions. The other sources (apps, zoxide, chrome) should default to enabled. Config for zoxidePath and enabled/disabled flags can be added later if needed. Actions require config because they define user commands.

### 4. No existing plist parsing in Swift server
The Go app source uses a plist library. Swift has native `PropertyListDecoder`/`PropertyListSerialization`, so this is straightforward.

### 5. ActionExecutor scope
The plan says "Create `ActionExecutor.swift`" — but `PickerManager.executeAction(for:)` already exists and handles `.focusWindow` and `.openApp`. The question is whether to extract to a separate file or extend in place.

**Decision recommendation:** Extend PickerAction with the new cases, keep routing in PickerManager. Create ActionExecutor as a stateless utility for the subprocess-heavy actions (exec, open-dir, open-chrome-profile). This avoids scattering Process() calls across PickerManager.

### 6. tmux binary path for open-dir
The Go `openDirInTmux` uses `tmux.FindTmux()`. Swift already has `findTmux()` in EnrichmentTypes.swift. Reusable.

## Prerequisites
- [x] PickerSource protocol exists and is proven (WindowSource works)
- [x] PickerManager.discoverAndStream() already supports multiple sources via TaskGroup
- [x] Spinner already exists in PickerWindow
- [x] PickerHistory.sourceBoost already recognizes all planned source ID prefixes
- [x] runProcess() subprocess helper exists
- [x] Go reference implementations available for all four sources + executor
- [x] findTmux() exists for open-dir action
- [ ] Sources/ subdirectory needs creating
- [ ] ServerConfig needs picker actions config
- [ ] PickerAction needs new cases

## Recommendation
**BUILD** — All prerequisites met. Clear reference implementations exist. Infrastructure (protocol, TaskGroup streaming, spinner, frecency) is in place. Four source files + executor + minor modifications to existing files.
