# Pseudocode: Phase 1 - Foundation Types + Config

## Files to Create/Modify

### Create
- `grid-server/Sources/GridServer/Grid/GridTypes.swift`
- `grid-server/Sources/GridServer/Grid/GridConfig.swift`

### Modify
- `grid-server/Sources/GridServer/main.swift` — wire GridConfig init, remove ServerConfig
- `grid-server/Sources/GridServer/MessageHandler.swift` — update ServerConfig references to GridConfig
- `grid-server/Sources/GridServer/Picker/Sources/ActionSource.swift` — update ServerConfig refs
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` — update ServerConfig refs

### Delete
- `grid-server/Sources/GridServer/ServerConfig.swift` — absorbed into GridConfig

---

## Pseudocode

### Grid/GridTypes.swift

```
// MARK: - Direction

// enum GridDirection: String, Codable, Sendable
//   cases: left, right, up, down
//
//   // Parse from string (failable)
//   static init?(from string: String) -> match lowercase against cases

// MARK: - Stack Mode

// enum GridStackMode: String, Codable, Sendable
//   cases: vertical, horizontal, tabs
//
//   Defaults to "tabs" when not specified

// MARK: - Track Types

// enum GridTrackType: String, Codable, Sendable
//   cases: fr, px, auto, minmax

// struct GridTrackSize: Equatable, Sendable
//   type: GridTrackType
//   value: Double    — primary value (for fr/px)
//   min: Double      — minimum (for minmax, in px)
//   max: Double      — maximum (for minmax, in fr)
//
//   // Parse from string
//   static func parse(_ string: String) throws -> GridTrackSize
//     Trim whitespace
//     If string == "auto" -> return .auto type
//     If matches pattern "Nfr" (digits/decimal + "fr") -> return .fr type with parsed value
//     If matches pattern "Npx" (digits/decimal + "px") -> return .px type with parsed value
//     If matches pattern "minmax(Npx, Nfr)" -> return .minmax type with min=px, max=fr
//     Otherwise throw GridConfigError.invalidTrackSize(string)
//
//   // Format back to string (for serialization)
//   var description: String
//     Switch on type:
//       .fr -> format value + "fr"
//       .px -> format value + "px"
//       .auto -> "auto"
//       .minmax -> "minmax(\(min)px, \(max)fr)"

// MARK: - Padding

// struct GridPaddingValue: Equatable, Sendable
//   pixels: Double       — fixed pixel value
//   baseMultiple: Double — multiplier for baseSpacing (e.g., 2.0 for "2x")
//   isRelative: Bool     — true if using baseMultiple
//
//   func resolve(baseSpacing: Double) -> Double
//     If isRelative: return baseMultiple * baseSpacing
//     Else: return pixels
//
//   // Parse from a single value (string, int, or double from YAML)
//   static func parse(_ value: Any) throws -> GridPaddingValue
//     If value is Int -> return GridPaddingValue(pixels: Double(value))
//     If value is Double -> return GridPaddingValue(pixels: value)
//     If value is String:
//       If ends with "x" -> parse number before "x" as baseMultiple, isRelative=true
//       If ends with "px" -> parse number before "px" as pixels
//       Otherwise -> try parse as plain number -> pixels
//     Throw invalidPaddingValue

// struct GridPadding: Equatable, Sendable
//   top: GridPaddingValue
//   right: GridPaddingValue
//   bottom: GridPaddingValue
//   left: GridPaddingValue
//
//   func resolve(baseSpacing: Double) -> GridResolvedPadding
//     Resolve all four sides
//
//   var isZero: Bool
//     All four sides have zero pixels and zero baseMultiple and not relative
//
//   // Parse from YAML Any value (supports all shorthand formats)
//   static func parse(_ raw: Any?) throws -> GridPadding?
//     If raw is nil -> return nil
//     If raw is Int or Double -> uniform padding from pixels
//     If raw is String -> parse as single value, apply to all sides
//     If raw is [Any] (array):
//       If count == 2 -> [vertical, horizontal]
//       If count == 4 -> [top, right, bottom, left] (CSS order)
//       Otherwise throw error
//     If raw is [String: Any] (object):
//       Parse keys "top", "right", "bottom", "left" individually
//     Otherwise throw invalidPaddingFormat

// struct GridResolvedPadding: Sendable
//   top: Double
//   right: Double
//   bottom: Double
//   left: Double

// MARK: - Cell Border Config

// struct GridCellBorderConfig: Codable, Sendable
//   activeCellColor: String?
//   inactiveColor: String?
//   style: String?

// MARK: - Cell Definition

// struct GridCellDef: Sendable
//   id: String
//   columnStart: Int   — 1-indexed
//   columnEnd: Int     — 1-indexed, exclusive
//   rowStart: Int      — 1-indexed
//   rowEnd: Int        — 1-indexed, exclusive
//   stackMode: GridStackMode?    — per-cell override
//   padding: GridPadding?        — per-cell padding override
//   windowSpacing: GridPaddingValue?  — per-cell window spacing override
//   border: GridCellBorderConfig?     — per-cell border style override

// MARK: - Layout Definition

// struct GridLayoutDef: Sendable
//   id: String
//   name: String
//   description: String
//   columns: [GridTrackSize]
//   rows: [GridTrackSize]
//   cells: [GridCellDef]
//   cellModes: [String: GridStackMode]  — per-cell stack mode overrides
//   padding: GridPadding?               — layout-level default padding
//   windowSpacing: GridPaddingValue?    — layout-level window spacing

// MARK: - Assignment Strategy (used in later phases)

// enum GridAssignmentStrategy: Sendable
//   cases: autoFlow, pinned, preserve, position

// MARK: - Errors

// enum GridConfigError: Error, LocalizedError
//   case invalidTrackSize(String)
//   case invalidPaddingValue(String)
//   case invalidPaddingFormat(String)
//   case invalidSpan(String)
//   case layoutNotFound(String)
//   case validationError(String)
//   case noConfigFound(searchedPaths: [String])
```

**Design Notes for GridTypes:**
- No custom `Rect` or `Point` types. Use `CGRect` and `CGPoint` from CoreGraphics. Go's `Rect` had custom methods (`Center`, `Contains`, `Overlap`) -- these become CGRect extensions added in Phase 3 when needed.
- `CalculatedLayout`, `CellBounds`, `WindowPlacement` types are NOT included here. They belong to Phase 3 (Layout Computation) where they're actually used.
- All types are `Sendable` for actor isolation compatibility.
- `GridDirection` and `GridAssignmentStrategy` are defined here even though used in later phases -- they're fundamental enums used across the codebase.

---

### Grid/GridConfig.swift

```
// import Foundation
// import Yams

// MARK: - YAML Config Structures (Codable for Yams decoding)

// struct GridSettingsYAML: Codable
//   defaultStackMode: String?
//   animationDuration: Double?
//   baseSpacing: Double?
//   padding: Any?          — uses AnyCodable or custom decoding for shorthand
//   windowSpacing: Any?    — same
//   focusFollowsMouse: Bool?
//   resize: GridResizeSettingsYAML?
//   windowExclusion: GridWindowExclusionYAML?
//   displayOffsets: [String: GridDisplayOffsetYAML]?
//   recording: GridRecordingSettingsYAML?

// struct GridResizeSettingsYAML: Codable
//   minRatio: Double?
//   maxRatio: Double?

// struct GridRecordingSettingsYAML: Codable
//   outputDir: String?

// struct GridWindowExclusionYAML: Codable
//   roles: [String]?
//   subroles: [String]?
//   apps: [String]?

// struct GridDisplayOffsetYAML: Codable
//   x: Double
//   y: Double

// struct GridGridYAML: Codable
//   columns: [String]
//   rows: [String]

// struct GridCellBorderYAML: Codable
//   activeCellColor: String?   (coding key: active_cell_color)
//   inactiveColor: String?     (coding key: inactive_color)
//   style: String?

// struct GridCellYAML: Codable
//   id: String
//   column: String           — "start/end" format
//   row: String              — "start/end" format
//   stackMode: String?
//   padding: AnyCodable?     — shorthand
//   windowSpacing: AnyCodable? — shorthand
//   border: GridCellBorderYAML?

// struct GridLayoutYAML: Codable
//   id: String
//   name: String?
//   description: String?
//   grid: GridGridYAML
//   areas: [[String]]?
//   cells: [GridCellYAML]?
//   cellModes: [String: String]?
//   padding: AnyCodable?
//   windowSpacing: AnyCodable?

// struct GridLayoutOverrideYAML: Codable
//   grid: GridGridYAML?
//   cellModes: [String: String]?

// struct GridSpaceConfigYAML: Codable
//   name: String?
//   layouts: [String]
//   defaultLayout: String
//   autoApply: Bool?

// struct GridAppRuleYAML: Codable
//   app: String
//   preferredCell: String?
//   layouts: [String]?
//   float: Bool?
//   preferredStackMode: String?

// NOTE ON BORDER CONFIG YAML:
// The border config YAML structure is complex with legacy compat.
// We do NOT define Codable structs for it. Instead, we extract the
// "borders" key as [String: Any] from the merged YAML dict and pass
// it directly to BorderConfigManager.shared.update(from:).
// This reuses all existing border parsing logic.

// NOTE ON PICKER CONFIG YAML:
// Same approach as borders. The picker section uses existing
// ActionDef/PickerSourceConfig types from ServerConfig.swift.
// We decode picker separately after merging.

// MARK: - Parsed Config (runtime representation)

// struct GridSettings: Sendable
//   defaultStackMode: GridStackMode
//   animationDuration: Double
//   baseSpacing: Double
//   padding: GridPadding?           — parsed from shorthand
//   windowSpacing: GridPaddingValue? — parsed from shorthand
//   focusFollowsMouse: Bool
//   resize: GridResizeSettings
//   windowExclusion: GridWindowExclusion
//   displayOffsets: [String: GridDisplayOffset]
//   recording: GridRecordingSettings

// struct GridResizeSettings: Sendable
//   minRatio: Double   — default 0.1
//   maxRatio: Double   — default 0.9

// struct GridRecordingSettings: Sendable
//   outputDir: String

// struct GridWindowExclusion: Sendable
//   roles: [String]
//   subroles: [String]
//   apps: [String]
//
//   // Merge with defaults (additive)
//   func mergedWithDefaults() -> GridWindowExclusion
//     Start with default roles (AXHelpTag, AXGrowArea, AXScrollArea)
//     Add user roles that aren't already present
//     Start with default apps (Dock, Control Center, Notification Center)
//     Add user apps that aren't already present
//     Return merged

// struct GridDisplayOffset: Sendable
//   x: Double
//   y: Double

// struct GridSpaceConfig: Sendable
//   name: String?
//   layouts: [String]
//   defaultLayout: String
//   autoApply: Bool

// struct GridAppRule: Sendable
//   app: String
//   preferredCell: String?
//   layouts: [String]?
//   float: Bool
//   preferredStackMode: GridStackMode?

// MARK: - Built-in Layouts

// enum GridBuiltinLayouts
//   static let all: [String: GridLayoutYAML] = [
//     "single-tabbed": GridLayoutYAML(
//       id: "single-tabbed", name: "Single Tabbed",
//       grid: GridGridYAML(columns: ["1fr"], rows: ["1fr"]),
//       cells: [GridCellYAML(id: "main", column: "1/2", row: "1/2")],
//       cellModes: ["main": "tabs"]
//     ),
//     "two-column-tabs": GridLayoutYAML(
//       id: "two-column-tabs", name: "Two Column Tabs",
//       grid: GridGridYAML(columns: ["1fr", "1fr"], rows: ["1fr"]),
//       cells: [
//         GridCellYAML(id: "left", column: "1/2", row: "1/2"),
//         GridCellYAML(id: "right", column: "2/3", row: "1/2")
//       ],
//       cellModes: ["left": "tabs", "right": "tabs"]
//     )
//   ]

// MARK: - Areas-to-Cells Conversion

// func areasToGridCells(areas: [[String]]) -> [GridCellDef]
//   For each unique cell ID found in the areas grid:
//     Track the min/max row and column positions
//     Skip "." and "" (empty cells)
//   Convert to GridCellDef with 1-indexed positions
//   Return cells in order of first appearance

// MARK: - Span Parsing

// func parseSpan(_ span: String) throws -> (start: Int, end: Int)
//   Split on "/"
//   If not exactly 2 parts, throw invalidSpan
//   Parse both parts as Int
//   Return (start, end)

// MARK: - GridConfig (main config object)

// @MainActor
// final class GridConfig
//
//   // Published state
//   private(set) var settings: GridSettings
//   private(set) var layouts: [GridLayoutYAML]  — raw YAML layouts for later conversion
//   private(set) var layoutOverrides: [String: GridLayoutOverrideYAML]
//   private(set) var spaces: [String: GridSpaceConfig]
//   private(set) var appRules: [GridAppRule]
//
//   // Absorbed from ServerConfig
//   private(set) var windowBlacklist: [String]
//   private(set) var pickerActions: [ActionDef]
//   private(set) var zoxidePath: String?
//
//   // File watcher
//   private var configWatcher: DispatchSourceFileSystemObject?
//   private var localConfigWatcher: DispatchSourceFileSystemObject?
//   private var pendingReload: DispatchWorkItem?
//
//   // Reload callback (for later phases to subscribe)
//   var onReload: (() -> Void)?
//
//   // MARK: - Initialization
//
//   init()
//     Set all fields to defaults (empty arrays, default settings)
//
//   // Load config using XDG resolution
//   func load() async throws
//     Find config files using XDG.findConfigFiles(app: "thegrid", filename: "config.yaml")
//     Start with builtin defaults map
//     For each found file:
//       Read file data
//       Parse YAML to [String: Any]
//       Deep merge into accumulated map
//     Load local overlay (config.local.yaml) if exists
//       Deep merge into accumulated map
//     If no files found and no local file -> throw noConfigFound
//
//     // Parse the merged dictionary
//     Convert merged dict back to YAML string
//     Decode as a temporary Codable struct (or parse sections individually)
//
//     // Extract and parse each section:
//     parseSettings(from merged dict)
//     parseLayouts(from merged dict)
//     parseLayoutOverrides(from merged dict)
//     parseSpaces(from merged dict)
//     parseAppRules(from merged dict)
//     parseServerFields(from merged dict)  — windowBlacklist, picker
//
//     // Bridge border config to BorderConfigManager
//     If merged dict has "borders" key:
//       Pass borders dict to BorderConfigManager.shared.update(from:)
//
//     // Validate
//     validate()
//
//     // Expand paths (tilde expansion)
//     expandPaths()
//
//     // Start file watchers
//     startConfigWatchers()
//
//   // MARK: - Layout Access
//
//   func getLayout(id: String) throws -> GridLayoutDef
//     Search layouts array by ID
//     If not found, check GridBuiltinLayouts.all[id]
//     If still not found, throw layoutNotFound
//
//     Get the layout YAML struct
//     If layoutOverrides has entry for this ID:
//       Clone the layout YAML
//       Apply grid overrides (columns, rows) if present in override
//       Merge cellModes from override into cloned
//
//     Convert layout YAML to GridLayoutDef:
//       Parse each column string -> GridTrackSize
//       Parse each row string -> GridTrackSize
//       If areas present: convert areas to cells via areasToGridCells
//       Else: convert each cell YAML to GridCellDef (parse spans, padding, etc.)
//       Parse layout-level padding and windowSpacing
//       Map cellModes strings to GridStackMode
//
//     Return GridLayoutDef
//
//   func getLayoutIDs() -> [String]
//     Return IDs from layouts array
//
//   func getSpaceConfig(spaceID: String) -> GridSpaceConfig?
//     Look up in spaces dictionary
//
//   func getAppRule(appName: String, bundleID: String) -> GridAppRule?
//     Search appRules for matching app or bundleID
//
//   func getDisplayOffset(uuid: String, name: String) -> GridDisplayOffset
//     Check displayOffsets[uuid] first, then displayOffsets[name]
//     Return zero offset if no match
//
//   func getBaseSpacing() -> Double
//     Return settings.baseSpacing if > 0, else 8.0
//
//   func getSettingsPadding() throws -> GridPadding?
//     Return settings.padding
//
//   func getSettingsWindowSpacing() throws -> GridPaddingValue?
//     Return settings.windowSpacing
//
//   func getWindowExclusions() -> GridWindowExclusion
//     Return settings.windowExclusion.mergedWithDefaults()
//
//   // MARK: - Validation
//
//   private func validate() throws
//     Validate layouts:
//       Each layout must have an ID (no duplicates)
//       Each layout must have grid.columns and grid.rows (non-empty)
//       Each track size string must be parseable
//       Must have either cells or areas (not neither)
//       If cells: validate cell spans are within grid bounds
//       If areas: validate row count == grid rows, col count == grid columns
//         Validate each cell forms a rectangle
//     Validate spaces reference existing layout IDs
//     Validate app rules have non-empty app field
//     Validate settings:
//       defaultStackMode is valid if set
//       animationDuration >= 0
//       baseSpacing >= 0
//
//   // MARK: - File Watching
//
//   private func startConfigWatchers()
//     Watch config.yaml at XDG.configHome + "/thegrid/config.yaml"
//     Watch config.local.yaml at XDG.configHome + "/thegrid/config.local.yaml"
//     Both use DispatchSource.makeFileSystemObjectSource pattern from BFDManager
//     Both trigger debounced reload (100ms delay)
//
//   private func startWatcher(path: String) -> DispatchSourceFileSystemObject?
//     Open file with O_EVTONLY
//     If fd < 0, return nil (file doesn't exist yet)
//     Create DispatchSource with eventMask: [.write, .delete, .rename, .extend]
//     On event: cancel pending reload, schedule new reload after 100ms
//     Set cancel handler to close fd
//     Resume source
//     Return source
//
//   private func stopConfigWatchers()
//     Cancel and nil both watcher sources
//
//   private func reload() async
//     Log reload start
//     Do:
//       Call load() again (re-reads all files, re-merges, re-validates)
//       Log reload success
//       Call onReload callback
//       // Border config is re-bridged during load()
//     Catch:
//       Log reload error (but keep old config)
//
//   // MARK: - Path Expansion
//
//   private func expandPaths()
//     Expand tilde in settings.recording.outputDir
//     Expand tilde in zoxidePath
//
//   // MARK: - Parsing Helpers
//
//   private func parseSettings(from dict: [String: Any]) throws
//     Extract "settings" sub-dict
//     Parse defaultStackMode (default: .tabs)
//     Parse animationDuration (default: 0)
//     Parse baseSpacing (default: 8)
//     Parse padding via GridPadding.parse()
//     Parse windowSpacing via GridPaddingValue.parse()
//     Parse focusFollowsMouse (default: false)
//     Parse resize sub-dict (minRatio default 0.1, maxRatio default 0.9)
//     Parse windowExclusion sub-dict
//     Parse displayOffsets sub-dict
//     Parse recording sub-dict
//
//   private func parseLayouts(from dict: [String: Any]) throws
//     Extract "layouts" array from dict
//     Decode as YAML string -> [GridLayoutYAML] using YAMLDecoder
//     Store in self.layouts
//
//   private func parseLayoutOverrides(from dict: [String: Any]) throws
//     Extract "layoutOverrides" sub-dict
//     Decode as YAML string -> [String: GridLayoutOverrideYAML]
//     Store in self.layoutOverrides
//
//   private func parseSpaces(from dict: [String: Any]) throws
//     Extract "spaces" sub-dict
//     For each key-value:
//       Decode as GridSpaceConfigYAML -> convert to GridSpaceConfig
//     Store in self.spaces
//
//   private func parseAppRules(from dict: [String: Any]) throws
//     Extract "appRules" array
//     Decode as YAML string -> [GridAppRuleYAML]
//     Convert each to GridAppRule
//     Store in self.appRules
//
//   private func parseServerFields(from dict: [String: Any])
//     Extract "window_blacklist" or "windowBlacklist" array -> self.windowBlacklist
//     Extract "picker" sub-dict:
//       Decode actions array -> self.pickerActions
//       Extract zoxidePath -> self.zoxidePath
```

**Design Decision: Parsing Strategy**

Instead of trying to decode the entire merged `[String: Any]` dict through a single Codable struct (which breaks on `Any`-typed padding fields), we use a hybrid approach:

1. Sections with straightforward types (layouts, spaces, appRules) are re-serialized to YAML and decoded via `YAMLDecoder` into their respective Codable structs.
2. Sections with polymorphic types (settings.padding, settings.windowSpacing, cell padding) are parsed manually from the `[String: Any]` dict using the `GridPadding.parse()` / `GridPaddingValue.parse()` functions.
3. The `borders` section is passed as-is to `BorderConfigManager.shared.update(from:)`.

This avoids fighting Codable's type system for the shorthand padding formats while still getting type-safe decoding for the rest.

---

### Modifications to main.swift

```
// In GridServerCommand.run():
//
// BEFORE (current):
//   [no GridConfig]
//   ServerConfig used implicitly via PickerManager
//
// AFTER:
//   // After StateManager init, before BFD init:
//   let gridConfig = GridConfig()
//   Task {
//     do {
//       try await gridConfig.load()
//       jlog("grid.cfg.ready")
//     } catch {
//       jlog("err.grid.cfg", data: ["err": "\(error)"])
//       // Server can still run without grid config (BFD + borders still work)
//     }
//   }
//
//   // Pass gridConfig to components that need it:
//   // PickerManager uses gridConfig.pickerActions, gridConfig.zoxidePath
//   // MessageHandler may need gridConfig for RPC handlers (later phases)
//
//   // The border bridge happens inside gridConfig.load() automatically
```

### Modifications to absorb ServerConfig

```
// Files that reference ServerConfig:
//   - main.swift (implicitly, via PickerManager)
//   - PickerManager.swift (uses ServerConfig.picker for actions)
//   - Picker/Sources/ActionSource.swift (uses ActionDef)
//   - MessageHandler.swift (has serverConfig reference)
//
// Changes:
//   - ActionDef struct moves from ServerConfig.swift to GridConfig.swift
//     (or stays standalone as a shared type)
//   - PickerManager receives actions + zoxidePath from GridConfig instead of ServerConfig
//   - MessageHandler receives GridConfig reference instead of ServerConfig
//   - ServerConfig.swift is deleted
//
// NOTE: PickerSourceConfig struct is used by PickerManager. Its fields
// (actions, zoxidePath) are absorbed into GridConfig's top-level properties.
// The Codable struct itself is no longer needed.
```

---

## Design: GridConfig

### Approaches Considered

1. **Actor-based GridConfig** - Make GridConfig a Swift actor for thread safety. All access goes through async calls.
2. **@MainActor class** - Pin to main actor. Config is read during UI operations (border updates, layout apply), which already run on main. Simple property access without async.
3. **Struct with shared reference** - Immutable struct rebuilt on reload, stored in a shared reference. Readers get a snapshot.

### Comparison

| Criterion | Actor | @MainActor class | Struct+ref |
|-----------|-------|------------------|------------|
| Interface simplicity | Async everywhere | Direct property access on main | Need to get snapshot |
| Information hiding | Good | Good | Moderate |
| Caller ease of use | Verbose (await) | Simple | Moderate |
| Thread safety | Built-in | Main-actor guarantee | Lock needed |
| Fits existing patterns | No (BFD/borders use main queue) | Yes | No |

### Choice: @MainActor class

Rationale: The server's existing pattern (BFDManager, SimpleBorderManager, BorderEvents) uses main-queue dispatch. Config is read during layout apply and border sync, which happen on main. Making GridConfig `@MainActor` matches this pattern and avoids async overhead for simple property reads. The file watcher already runs on `.main` queue.

### Depth Check
- Interface methods: ~10 public (load, getLayout, getLayoutIDs, getSpaceConfig, getAppRule, getDisplayOffset, getBaseSpacing, getSettingsPadding, getSettingsWindowSpacing, getWindowExclusions)
- Hidden details: YAML parsing, XDG resolution, deep merge, file watching, border bridging, validation, tilde expansion, areas-to-cells conversion, span parsing, track size parsing, padding shorthand parsing
- Common case complexity: Simple (call `getLayout("dev")`, get back a `GridLayoutDef`)

---

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (GridConfig design-it-twice comparison above)
- [x] Ready for implementation
