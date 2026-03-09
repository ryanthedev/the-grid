# Discovery: Phase 1 - Foundation Types + Config

## Files Found

### Go Sources (to port)
- `grid-cli/internal/types/layout_types.go` (227 lines) - All core types: Direction, StackMode, TrackType, TrackSize, PaddingValue, Padding, Cell, Layout, Rect, CellBounds, WindowPlacement, CalculatedLayout, AssignmentStrategy
- `grid-cli/internal/config/types.go` (343 lines) - Config, Settings, LayoutConfig, GridConfig, CellConfig, SpaceConfig, AppRule, BorderConfig (with legacy compat), PickerConfig, AnimationConfig, BorderStyle
- `grid-cli/internal/config/config.go` (404 lines) - GetLayout, ToLayout, ToCell, ExpandPaths, GetDisplayOffset, GetAppRule, GetSpaceConfig, GetBaseSpacing, GetSettingsPadding, GetSettingsWindowSpacing, GetWindowExclusions
- `grid-cli/internal/config/loader.go` (370 lines) - XDG loading, deep merge, caching, layered merge
- `grid-cli/internal/config/parser.go` (292 lines) - ParseTrackSize (regex), AreasToCell, ParsePadding (shorthand), FormatTrackSize
- `grid-cli/internal/config/validate.go` (236 lines) - Validate, validateLayout, validateCellConfig, validateAreas, isRectangular, parseSpan
- `grid-cli/internal/config/builtin.go` (44 lines) - builtinLayouts map (single-tabbed, two-column-tabs)

### Swift Server (existing, to reuse/absorb)
- `grid-server/Sources/GridServer/XDG.swift` (94 lines) - XDG enum with configHome, configDirs, stateHome, findConfigFiles. Already async.
- `grid-server/Sources/GridServer/DeepMerge.swift` (34 lines) - deepMerge function, identical semantics to Go version.
- `grid-server/Sources/GridServer/ServerConfig.swift` (133 lines) - ServerConfig struct (windowBlacklist, cliPath, picker). Uses XDG + Yams + deepMerge. TO BE ABSORBED into GridConfig.
- `grid-server/Sources/GridServer/BFD/BFDConfig.swift` (228 lines) - BFDConfig struct. Uses same XDG + Yams + deepMerge pattern. Has `load()` method to copy.
- `grid-server/Sources/GridServer/BFD/BFDManager.swift` (188 lines) - Has `startConfigWatcher()` using `DispatchSource.makeFileSystemObjectSource` with debounced reload. Pattern to reuse.
- `grid-server/Sources/GridServer/Borders/SimpleBorderConfig.swift` (509 lines) - BorderConfigManager singleton. Has `update(from:)` that takes `[String: Any]` dict. Parses hex colors, clamps values, notifies via `onConfigChanged` callback.
- `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` (968 lines) - The border manager. Receives config changes via `BorderConfigManager.shared.onConfigChanged`.
- `grid-server/Sources/GridServer/Borders/BorderEvents.swift` (38 lines) - Currently a no-op (`handle` does nothing). Plan says to activate this in Phase 4.
- `grid-server/Sources/GridServer/main.swift` (173 lines) - Server init. Creates SimpleBorderManager, BorderEvents, StateManager, BFDManager. No GridConfig yet.

### Target Files (to create)
- `grid-server/Sources/GridServer/Grid/GridTypes.swift` - DOES NOT EXIST
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` - DOES NOT EXIST
- `grid-server/Sources/GridServer/Grid/` directory - DOES NOT EXIST

## Current State

### Types
- No Swift equivalents of `GridDirection`, `GridStackMode`, `GridTrackType`, `GridTrackSize`, `GridPadding`, `GridCellDef`, `GridLayoutDef` exist in the server.
- The server uses `CGRect` for rectangles (no custom Rect type needed -- use CGRect directly).
- Border types exist in `SimpleBorderConfig.swift` but are runtime config objects, not YAML config types.

### Config Loading
- Two independent config loaders exist: `ServerConfig.load()` and `BFDConfig.load()`. Both use the same pattern: XDG resolution, Yams, deepMerge, local overlay.
- ServerConfig currently only reads `window_blacklist`, `cli_path`, and `picker` from the YAML. It ignores all grid-related config (layouts, settings, spaces, appRules, borders).
- BFDConfig reads from `bfd.yaml` (separate file). It is NOT being absorbed -- it stays separate.
- The grid config (`config.yaml`) contains ALL of: settings, layouts, layoutOverrides, spaces, appRules, borders, picker. ServerConfig only reads a subset.

### Border Config Bridge
- `BorderConfigManager.shared.update(from:)` already accepts a `[String: Any]` dictionary and updates border styles. It handles both new nested schema and legacy flat schema.
- Currently, border config comes via RPC from the Go CLI (`borders.sync` RPC). After migration, it should come directly from `GridConfig.borders` on load/reload.

## Gaps

1. **No Grid directory exists.** Must create `grid-server/Sources/GridServer/Grid/`.
2. **No Swift type equivalents for Go layout types.** Must port all types from `layout_types.go`.
3. **No config loader for grid-specific config.** ServerConfig only loads server-specific fields. Need a full config loader that reads layouts, settings, spaces, appRules, borders.
4. **ServerConfig absorption.** ServerConfig's fields (`windowBlacklist`, `cliPath`, `picker`) need to be folded into `GridConfig`. After absorption, `ServerConfig.swift` can be deleted and all references updated.
5. **Padding parsing is complex.** Go's `ParsePadding` handles 6 input formats (number, string, array-2, array-4, object, nil). Yams deserializes YAML differently than Go's `yaml.v3` -- need to handle `Any` type dispatch carefully.
6. **Track size parsing is regex-based.** Three regex patterns: `fr`, `px`, `minmax`. Port directly; Swift's `NSRegularExpression` or string parsing works.
7. **Config caching.** Go has a cache layer (`config.merged.yaml` in XDG cache home). The Swift server doesn't need this -- it loads once at startup and hot-reloads on change. Skip caching.
8. **File watcher scope.** BFD watches a single file (`bfd.yaml`). GridConfig needs to watch `config.yaml` AND `config.local.yaml`. The DispatchSource pattern only watches one fd. Either watch the directory or watch both files.
9. **LayoutOverrides.** Go config supports `layoutOverrides` map that patches a layout's grid and cellModes. Must port the clone-and-merge logic in `GetLayout()`.

## Prerequisites

- [x] Go source files exist and are readable
- [x] Swift server infrastructure exists (XDG, DeepMerge, Yams, Borders)
- [x] BFD config watcher pattern available to copy
- [x] BorderConfigManager has `update(from:)` method ready to receive config
- [x] main.swift has clear initialization point to wire GridConfig
- [x] No conflicting Grid/ directory or types

## Recommendation

**BUILD** - All prerequisites are met. No Grid/ directory or types exist yet. The Go sources are well-structured and the Swift server has all the infrastructure pieces (XDG, deepMerge, Yams, DispatchSource watcher). The ServerConfig is small enough to absorb cleanly.
