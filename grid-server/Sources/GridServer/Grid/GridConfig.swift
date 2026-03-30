import Foundation
import Yams

// MARK: - Action Definition (from ServerConfig, used by Picker)

struct ActionDef: Codable {
    var name: String = ""
    var command: String = ""
    var category: String?
    var icon: String?
}

// MARK: - YAML Config Structures

struct GridGridYAML: Codable {
    var columns: [String]
    var rows: [String]
}

struct GridCellBorderYAML: Codable {
    var activeCellColor: String?
    var inactiveColor: String?
    var style: String?

    enum CodingKeys: String, CodingKey {
        case activeCellColor = "active_cell_color"
        case inactiveColor = "inactive_color"
        case style
    }
}

struct GridCellYAML: Codable {
    var id: String
    var column: String
    var row: String
    var stackMode: String?
    var padding: AnyCodable?
    var windowSpacing: AnyCodable?
    var border: GridCellBorderYAML?

    enum CodingKeys: String, CodingKey {
        case id, column, row, stackMode, padding, windowSpacing, border
    }
}

struct GridLayoutYAML: Codable {
    var id: String
    var name: String?
    var description: String?
    var grid: GridGridYAML
    var areas: [[String]]?
    var cells: [GridCellYAML]?
    var cellModes: [String: String]?
    var padding: AnyCodable?
    var windowSpacing: AnyCodable?
}

struct GridLayoutOverrideYAML: Codable {
    var grid: GridGridYAML?
    var cellModes: [String: String]?
}

struct GridSpaceConfigYAML: Codable {
    var name: String?
    var layouts: [String]
    var defaultLayout: String
    var autoApply: Bool?
}

struct GridAppRuleYAML: Codable {
    var app: String
    var preferredCell: String?
    var layouts: [String]?
    var float: Bool?
    var locked: Bool?
    var preferredStackMode: String?
}

// NOTE: AnyCodable is defined in Models/Message.swift and reused here
// for polymorphic YAML fields (padding, windowSpacing).

// MARK: - Parsed Config (runtime representation)

struct GridSettings: Sendable {
    var defaultStackMode: GridStackMode = .tabs
    var animationDuration: Double = 0
    var baseSpacing: Double = 8
    var padding: GridPadding?
    var windowSpacing: GridPaddingValue?
    var focusFollowsMouse: Bool = false
    var resize: GridResizeSettings = GridResizeSettings()
    var windowExclusion: GridWindowExclusion = GridWindowExclusion()
    var displayOffsets: [String: GridDisplayOffset] = [:]
    var recording: GridRecordingSettings = GridRecordingSettings()
}

struct GridResizeSettings: Sendable {
    var minRatio: Double = 0.1
    var maxRatio: Double = 0.9
}

struct GridRecordingSettings: Sendable {
    var outputDir: String = ""
}

struct GridWindowExclusion: Sendable {
    var roles: [String] = []
    var subroles: [String] = []
    var apps: [String] = []

    func mergedWithDefaults() -> GridWindowExclusion {
        let defaultRoles = ["AXHelpTag", "AXGrowArea", "AXScrollArea"]
        let defaultApps = ["Dock", "Control Center", "Notification Center"]

        var mergedRoles = defaultRoles
        for r in roles where !mergedRoles.contains(r) {
            mergedRoles.append(r)
        }

        var mergedSubroles = subroles

        var mergedApps = defaultApps
        for a in apps where !mergedApps.contains(a) {
            mergedApps.append(a)
        }

        return GridWindowExclusion(roles: mergedRoles, subroles: mergedSubroles, apps: mergedApps)
    }
}

struct GridDisplayOffset: Sendable {
    var x: Double = 0
    var y: Double = 0
}

struct GridSpaceConfig: Sendable {
    var name: String?
    var layouts: [String]
    var defaultLayout: String
    var autoApply: Bool
}

struct GridAppRule: Sendable {
    var app: String
    var preferredCell: String?
    var layouts: [String]?
    var float: Bool
    var locked: Bool
    var preferredStackMode: GridStackMode?
}

// MARK: - Built-in Layouts

enum GridBuiltinLayouts {
    static let all: [String: GridLayoutYAML] = [
        "single-tabbed": GridLayoutYAML(
            id: "single-tabbed",
            name: "Single Tabbed",
            grid: GridGridYAML(columns: ["1fr"], rows: ["1fr"]),
            cells: [GridCellYAML(id: "main", column: "1/2", row: "1/2")],
            cellModes: ["main": "tabs"]
        ),
        "two-column-tabs": GridLayoutYAML(
            id: "two-column-tabs",
            name: "Two Column Tabs",
            grid: GridGridYAML(columns: ["1fr", "1fr"], rows: ["1fr"]),
            cells: [
                GridCellYAML(id: "left", column: "1/2", row: "1/2"),
                GridCellYAML(id: "right", column: "2/3", row: "1/2"),
            ],
            cellModes: ["left": "tabs", "right": "tabs"]
        ),
    ]
}

// MARK: - Areas-to-Cells Conversion

func areasToGridCells(areas: [[String]]) -> [GridCellDef] {
    if areas.isEmpty { return [] }

    var cellBounds: [String: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)] = [:]

    for (rowIdx, row) in areas.enumerated() {
        for (colIdx, cellID) in row.enumerated() {
            if cellID == "." || cellID == "" { continue }
            let col = colIdx + 1
            let rowNum = rowIdx + 1

            if var existing = cellBounds[cellID] {
                if col < existing.minCol { existing.minCol = col }
                if col + 1 > existing.maxCol { existing.maxCol = col + 1 }
                if rowNum < existing.minRow { existing.minRow = rowNum }
                if rowNum + 1 > existing.maxRow { existing.maxRow = rowNum + 1 }
                cellBounds[cellID] = existing
            } else {
                cellBounds[cellID] = (minRow: rowNum, maxRow: rowNum + 1, minCol: col, maxCol: col + 1)
            }
        }
    }

    // Preserve order of first appearance
    var seen = Set<String>()
    var cells: [GridCellDef] = []
    for row in areas {
        for cellID in row {
            if cellID == "." || cellID == "" { continue }
            if seen.contains(cellID) { continue }
            seen.insert(cellID)
            if let bounds = cellBounds[cellID] {
                cells.append(GridCellDef(
                    id: cellID,
                    columnStart: bounds.minCol,
                    columnEnd: bounds.maxCol,
                    rowStart: bounds.minRow,
                    rowEnd: bounds.maxRow
                ))
            }
        }
    }

    return cells
}

// MARK: - Span Parsing

func parseSpan(_ span: String) throws -> (start: Int, end: Int) {
    let parts = span.split(separator: "/")
    guard parts.count == 2,
          let start = Int(parts[0]),
          let end = Int(parts[1]) else {
        throw GridConfigError.invalidSpan(span)
    }
    return (start, end)
}

// MARK: - Notifications Config (YAML decode structs, private to this file)

// Private Codable structs used only inside parseNotifications(from:).
// All YAML key names match config.yaml exactly.
private struct NotificationsYAML: Codable {
    // notifications:
    //   theme:
    //     background: "#121212"
    //     ... (all NotificationPanelTheme field names, by their Swift camelCase names)
    var theme: [String: String]?

    // notifications:
    //   max_count: 200
    var maxCount: Int?

    // notifications:
    //   event_rules:
    //     "ev.win.create":
    //       title: "Window Created"
    //       body: "{event}"
    //       priority: "normal"
    var eventRules: [String: EventRuleYAML]?

    // notifications:
    //   file_watcher:
    //     path: "~/.local/state/thegrid/notify.pipe"
    //     source_label: "pipe"
    var fileWatcher: FileWatcherYAML?

    enum CodingKeys: String, CodingKey {
        case theme
        case maxCount = "max_count"
        case eventRules = "event_rules"
        case fileWatcher = "file_watcher"
    }
}

private struct EventRuleYAML: Codable {
    var title: String
    var body: String?
    var priority: String?
}

private struct FileWatcherYAML: Codable {
    var path: String?
    var sourceLabel: String?

    enum CodingKeys: String, CodingKey {
        case path
        case sourceLabel = "source_label"
    }
}

// MARK: - GridNotificationsConfig

// Runtime representation of the notifications: config section.
// Callers access via gridConfig.notifications; no YAML details leak out.
struct GridNotificationsConfig: Sendable {
    // Keyed by event logInfo name (e.g. "ev.win.create"). Empty = no event notifications.
    var eventRules: [String: EventNotificationRule] = [:]
    // Path to watch for pipe/file notifications. Empty string = watcher disabled.
    var watcherPath: String = ""
    // Source label written into GridNotification.source for notifications from this watcher.
    var watcherSourceLabel: String = "pipe"
    // Maximum stored non-pinned notifications; 0 = unlimited.
    var maxCount: Int = 0
    // Raw hex color dict passed directly to NotificationPanelTheme.init(from:). Empty = use defaults.
    var themeColors: [String: String] = [:]
}

// MARK: - GridConfig

@MainActor
final class GridConfig {
    private(set) var settings: GridSettings = GridSettings()
    private(set) var layouts: [GridLayoutYAML] = []
    private(set) var layoutOverrides: [String: GridLayoutOverrideYAML] = [:]
    private(set) var spaces: [String: GridSpaceConfig] = [:]
    private(set) var appRules: [GridAppRule] = []
    private(set) var notifications: GridNotificationsConfig = GridNotificationsConfig()

    // Absorbed from ServerConfig
    private(set) var windowBlacklist: [String] = []
    private(set) var pickerActions: [ActionDef] = []
    private(set) var zoxidePath: String?

    // File watchers
    private var configWatcher: DispatchSourceFileSystemObject?
    private var localConfigWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    // Reload callback
    var onReload: (() -> Void)?

    nonisolated init() {}

    // MARK: - Load

    func load() async throws {
        let files = await XDG.findConfigFiles(app: "thegrid", filename: "config.yaml")

        JSONLogger.shared.log("grid.cfg.resolve", data: [
            "xdg_config_home": XDG.configHome,
            "files_found": files
        ])

        var merged: [String: Any] = [:]

        for file in files {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                guard let yaml = String(data: data, encoding: .utf8),
                      let dict = try Yams.load(yaml: yaml) as? [String: Any] else {
                    JSONLogger.shared.log("grid.cfg.skip", msg: "invalid yaml", data: ["file": file])
                    continue
                }
                merged = deepMerge(merged, dict)
                JSONLogger.shared.log("grid.cfg.merge", data: ["path": file])
            } catch {
                JSONLogger.shared.log("grid.cfg.skip", msg: "failed to read", data: ["file": file, "error": "\(error)"])
                continue
            }
        }

        // Load local overlay
        let localPath = "\(XDG.configHome)/thegrid/config.local.yaml"
        var hasLocal = false
        if FileManager.default.fileExists(atPath: localPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
                if let yaml = String(data: data, encoding: .utf8),
                   let dict = try Yams.load(yaml: yaml) as? [String: Any] {
                    merged = deepMerge(merged, dict)
                    hasLocal = true
                    JSONLogger.shared.log("grid.cfg.merge", data: ["path": localPath, "layer": "local"])
                }
            } catch {
                JSONLogger.shared.log("grid.cfg.skip", msg: "failed to read local", data: ["error": "\(error)"])
            }
        }

        if files.isEmpty && !hasLocal {
            var searched = XDG.configDirs.map { "\($0)/thegrid/config.yaml" }
            searched.append("\(XDG.configHome)/thegrid/config.yaml")
            throw GridConfigError.noConfigFound(searchedPaths: searched)
        }

        // Parse each section from the merged dictionary
        try parseSettings(from: merged)
        try parseLayouts(from: merged)
        try parseLayoutOverrides(from: merged)
        try parseSpaces(from: merged)
        try parseAppRules(from: merged)
        parseServerFields(from: merged)
        parseNotifications(from: merged)

        // Bridge border config to BorderConfigManager
        if let borders = merged["borders"] as? [String: Any] {
            BorderConfigManager.shared.update(from: borders)
            JSONLogger.shared.log("grid.cfg.borders.bridge")
        }

        // Validate
        try validate()

        // Expand paths
        expandPaths()

        // Start file watchers
        startConfigWatchers()
    }

    // MARK: - Layout Access

    func getLayout(id: String) throws -> GridLayoutDef {
        // Search user layouts
        var layoutYAML: GridLayoutYAML?
        for l in layouts {
            if l.id == id {
                layoutYAML = l
                break
            }
        }

        // Check builtins
        if layoutYAML == nil {
            layoutYAML = GridBuiltinLayouts.all[id]
        }

        guard var lc = layoutYAML else {
            throw GridConfigError.layoutNotFound(id)
        }

        // Apply overrides if present
        if let override = layoutOverrides[id] {
            if let gridOverride = override.grid {
                if !gridOverride.columns.isEmpty {
                    lc.grid.columns = gridOverride.columns
                }
                if !gridOverride.rows.isEmpty {
                    lc.grid.rows = gridOverride.rows
                }
            }
            if let modeOverrides = override.cellModes {
                var modes = lc.cellModes ?? [:]
                for (k, v) in modeOverrides {
                    modes[k] = v
                }
                lc.cellModes = modes
            }
        }

        return try convertLayoutYAMLToDef(lc)
    }

    func getLayoutIDs() -> [String] {
        layouts.map { $0.id }
    }

    func getSpaceConfig(spaceID: String) -> GridSpaceConfig? {
        spaces[spaceID]
    }

    func getAppRule(appName: String, bundleID: String) -> GridAppRule? {
        for rule in appRules {
            if rule.app == appName || rule.app == bundleID {
                return rule
            }
        }
        return nil
    }

    func getDisplayOffset(uuid: String, name: String) -> GridDisplayOffset {
        if !uuid.isEmpty, let offset = settings.displayOffsets[uuid] {
            return offset
        }
        if !name.isEmpty, let offset = settings.displayOffsets[name] {
            return offset
        }
        return GridDisplayOffset()
    }

    func getBaseSpacing() -> Double {
        settings.baseSpacing > 0 ? settings.baseSpacing : 8.0
    }

    func getSettingsPadding() -> GridPadding? {
        settings.padding
    }

    func getSettingsWindowSpacing() -> GridPaddingValue? {
        settings.windowSpacing
    }

    func getWindowExclusions() -> GridWindowExclusion {
        settings.windowExclusion.mergedWithDefaults()
    }

    // MARK: - Export

    func exportSummary() -> [String: Any] {
        var layoutSummaries: [[String: Any]] = []
        for l in layouts {
            layoutSummaries.append([
                "id": l.id,
                "name": l.name ?? l.id,
            ])
        }

        var settingsDict: [String: Any] = [
            "defaultStackMode": settings.defaultStackMode.rawValue,
            "baseSpacing": settings.baseSpacing,
            "focusFollowsMouse": settings.focusFollowsMouse,
            "animationDuration": settings.animationDuration,
        ]
        if let padding = settings.padding {
            settingsDict["padding"] = [
                "top": padding.top.resolve(baseSpacing: settings.baseSpacing),
                "right": padding.right.resolve(baseSpacing: settings.baseSpacing),
                "bottom": padding.bottom.resolve(baseSpacing: settings.baseSpacing),
                "left": padding.left.resolve(baseSpacing: settings.baseSpacing),
            ]
        }
        if let ws = settings.windowSpacing {
            settingsDict["windowSpacing"] = ws.resolve(baseSpacing: settings.baseSpacing)
        }

        return [
            "layouts": layoutSummaries,
            "spaces": Array(spaces.keys),
            "appRuleCount": appRules.count,
            "settings": settingsDict,
        ]
    }

    // MARK: - Validation

    private func validate() throws {
        var layoutIDs = Set<String>()
        for (i, layout) in layouts.enumerated() {
            if layout.id.isEmpty {
                throw GridConfigError.validationError("layout \(i): missing ID")
            }
            if layoutIDs.contains(layout.id) {
                throw GridConfigError.validationError("duplicate layout ID: \(layout.id)")
            }
            layoutIDs.insert(layout.id)

            try validateLayout(layout)
        }

        // Validate spaces reference existing layouts
        for (spaceID, spaceConfig) in spaces {
            for layoutID in spaceConfig.layouts {
                if !layoutIDs.contains(layoutID) && GridBuiltinLayouts.all[layoutID] == nil {
                    throw GridConfigError.validationError("space \(spaceID) references unknown layout: \(layoutID)")
                }
            }
            if !spaceConfig.defaultLayout.isEmpty
                && !layoutIDs.contains(spaceConfig.defaultLayout)
                && GridBuiltinLayouts.all[spaceConfig.defaultLayout] == nil {
                throw GridConfigError.validationError("space \(spaceID) has unknown default layout: \(spaceConfig.defaultLayout)")
            }
        }

        // Validate app rules
        for (i, rule) in appRules.enumerated() {
            if rule.app.isEmpty {
                throw GridConfigError.validationError("appRule \(i): missing app identifier")
            }
        }

        // Validate settings
        if settings.animationDuration < 0 {
            throw GridConfigError.validationError("animation duration cannot be negative")
        }
        if settings.baseSpacing < 0 {
            throw GridConfigError.validationError("base spacing cannot be negative")
        }
    }

    private func validateLayout(_ layout: GridLayoutYAML) throws {
        if layout.grid.columns.isEmpty {
            throw GridConfigError.validationError("layout \(layout.id): missing columns definition")
        }
        if layout.grid.rows.isEmpty {
            throw GridConfigError.validationError("layout \(layout.id): missing rows definition")
        }

        // Validate track sizes
        for (i, col) in layout.grid.columns.enumerated() {
            do {
                _ = try GridTrackSize.parse(col)
            } catch {
                throw GridConfigError.validationError("layout \(layout.id) column \(i): \(error)")
            }
        }
        for (i, row) in layout.grid.rows.enumerated() {
            do {
                _ = try GridTrackSize.parse(row)
            } catch {
                throw GridConfigError.validationError("layout \(layout.id) row \(i): \(error)")
            }
        }

        let hasCells = layout.cells != nil && !layout.cells!.isEmpty
        let hasAreas = layout.areas != nil && !layout.areas!.isEmpty

        if !hasCells && !hasAreas {
            throw GridConfigError.validationError("layout \(layout.id): must define either 'cells' or 'areas'")
        }

        let numCols = layout.grid.columns.count
        let numRows = layout.grid.rows.count

        if hasCells {
            var cellIDs = Set<String>()
            for cell in layout.cells! {
                if cell.id.isEmpty {
                    throw GridConfigError.validationError("layout \(layout.id): cell missing ID")
                }
                if cellIDs.contains(cell.id) {
                    throw GridConfigError.validationError("layout \(layout.id): duplicate cell ID: \(cell.id)")
                }
                cellIDs.insert(cell.id)

                let (colStart, colEnd) = try parseSpan(cell.column)
                let (rowStart, rowEnd) = try parseSpan(cell.row)
                if colStart < 1 || colEnd > numCols + 1 || colStart >= colEnd {
                    throw GridConfigError.validationError("layout \(layout.id) cell \(cell.id): column span \(colStart)/\(colEnd) out of bounds (grid has \(numCols) columns)")
                }
                if rowStart < 1 || rowEnd > numRows + 1 || rowStart >= rowEnd {
                    throw GridConfigError.validationError("layout \(layout.id) cell \(cell.id): row span \(rowStart)/\(rowEnd) out of bounds (grid has \(numRows) rows)")
                }

                if let mode = cell.stackMode, !mode.isEmpty {
                    if GridStackMode(rawValue: mode) == nil {
                        throw GridConfigError.validationError("layout \(layout.id) cell \(cell.id): invalid stack mode: \(mode)")
                    }
                }
            }
        }

        if hasAreas {
            let areas = layout.areas!
            if areas.count != numRows {
                throw GridConfigError.validationError("layout \(layout.id) areas: has \(areas.count) rows but grid defines \(numRows) rows")
            }
            for (i, row) in areas.enumerated() {
                if row.count != numCols {
                    throw GridConfigError.validationError("layout \(layout.id) areas: row \(i) has \(row.count) columns but grid defines \(numCols) columns")
                }
            }

            // Validate rectangularity
            var cellPositions: [String: [(Int, Int)]] = [:]
            for (rowIdx, row) in areas.enumerated() {
                for (colIdx, cellID) in row.enumerated() {
                    if cellID == "." || cellID == "" { continue }
                    cellPositions[cellID, default: []].append((rowIdx, colIdx))
                }
            }
            for (cellID, positions) in cellPositions {
                if !isRectangular(positions) {
                    throw GridConfigError.validationError("layout \(layout.id) areas: cell '\(cellID)' does not form a rectangle")
                }
            }
        }
    }

    private func isRectangular(_ positions: [(Int, Int)]) -> Bool {
        if positions.isEmpty { return false }
        let minRow = positions.map(\.0).min()!
        let maxRow = positions.map(\.0).max()!
        let minCol = positions.map(\.1).min()!
        let maxCol = positions.map(\.1).max()!
        let expected = (maxRow - minRow + 1) * (maxCol - minCol + 1)
        return positions.count == expected
    }

    // MARK: - File Watching

    private func startConfigWatchers() {
        stopConfigWatchers()
        let configPath = "\(XDG.configHome)/thegrid/config.yaml"
        let localPath = "\(XDG.configHome)/thegrid/config.local.yaml"
        configWatcher = startWatcher(path: configPath)
        localConfigWatcher = startWatcher(path: localPath)
    }

    private func startWatcher(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.pendingReload?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    await self?.reload()
                }
            }
            self.pendingReload = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return source
    }

    private func stopConfigWatchers() {
        configWatcher?.cancel()
        configWatcher = nil
        localConfigWatcher?.cancel()
        localConfigWatcher = nil
    }

    private func reload() async {
        jlog("grid.cfg.reload.start")
        do {
            try await load()
            jlog("grid.cfg.reload.ok")
            onReload?()
        } catch {
            jlog("err.grid.cfg.reload", data: ["err": "\(error)"])
        }
    }

    // MARK: - Path Expansion

    private func expandPaths() {
        settings.recording.outputDir = expandTilde(settings.recording.outputDir)
        if let zp = zoxidePath {
            zoxidePath = expandTilde(zp)
        }
    }

    private func expandTilde(_ path: String) -> String {
        if path.isEmpty { return path }
        return (path as NSString).expandingTildeInPath
    }

    // MARK: - Parsing Helpers

    private func parseSettings(from dict: [String: Any]) throws {
        guard let settingsDict = dict["settings"] as? [String: Any] else {
            settings = GridSettings()
            return
        }

        var s = GridSettings()

        if let mode = settingsDict["defaultStackMode"] as? String, !mode.isEmpty {
            if let sm = GridStackMode(rawValue: mode) {
                s.defaultStackMode = sm
            }
        }
        if let dur = settingsDict["animationDuration"] as? Double {
            s.animationDuration = dur
        } else if let dur = settingsDict["animationDuration"] as? Int {
            s.animationDuration = Double(dur)
        }
        if let bs = settingsDict["baseSpacing"] as? Double {
            s.baseSpacing = bs
        } else if let bs = settingsDict["baseSpacing"] as? Int {
            s.baseSpacing = Double(bs)
        }
        s.padding = try GridPadding.parse(settingsDict["padding"])
        if let ws = settingsDict["windowSpacing"] {
            s.windowSpacing = try GridPaddingValue.parse(ws)
        }
        if let ffm = settingsDict["focusFollowsMouse"] as? Bool {
            s.focusFollowsMouse = ffm
        }

        // Parse resize
        if let resizeDict = settingsDict["resize"] as? [String: Any] {
            if let minR = resizeDict["minRatio"] as? Double {
                s.resize.minRatio = minR
            }
            if let maxR = resizeDict["maxRatio"] as? Double {
                s.resize.maxRatio = maxR
            }
        }

        // Parse windowExclusion
        if let weDict = settingsDict["windowExclusion"] as? [String: Any] {
            if let roles = weDict["roles"] as? [String] {
                s.windowExclusion.roles = roles
            }
            if let subroles = weDict["subroles"] as? [String] {
                s.windowExclusion.subroles = subroles
            }
            if let apps = weDict["apps"] as? [String] {
                s.windowExclusion.apps = apps
            }
        }

        // Parse displayOffsets
        if let doDict = settingsDict["displayOffsets"] as? [String: Any] {
            for (key, val) in doDict {
                if let offsetDict = val as? [String: Any] {
                    var offset = GridDisplayOffset()
                    if let x = offsetDict["x"] as? Double { offset.x = x }
                    else if let x = offsetDict["x"] as? Int { offset.x = Double(x) }
                    if let y = offsetDict["y"] as? Double { offset.y = y }
                    else if let y = offsetDict["y"] as? Int { offset.y = Double(y) }
                    s.displayOffsets[key] = offset
                }
            }
        }

        // Parse recording
        if let recDict = settingsDict["recording"] as? [String: Any] {
            if let dir = recDict["outputDir"] as? String {
                s.recording.outputDir = dir
            }
        }

        settings = s
    }

    private func parseLayouts(from dict: [String: Any]) throws {
        guard let layoutsRaw = dict["layouts"] else {
            layouts = []
            return
        }
        // Re-serialize to YAML and decode
        let yamlStr = try Yams.dump(object: layoutsRaw)
        layouts = try YAMLDecoder().decode([GridLayoutYAML].self, from: yamlStr)
    }

    private func parseLayoutOverrides(from dict: [String: Any]) throws {
        guard let overridesRaw = dict["layoutOverrides"] else {
            layoutOverrides = [:]
            return
        }
        let yamlStr = try Yams.dump(object: overridesRaw)
        layoutOverrides = try YAMLDecoder().decode([String: GridLayoutOverrideYAML].self, from: yamlStr)
    }

    private func parseSpaces(from dict: [String: Any]) throws {
        guard let spacesDict = dict["spaces"] as? [String: Any] else {
            spaces = [:]
            return
        }
        var result: [String: GridSpaceConfig] = [:]
        for (key, val) in spacesDict {
            let yamlStr = try Yams.dump(object: val)
            let scYAML = try YAMLDecoder().decode(GridSpaceConfigYAML.self, from: yamlStr)
            result[key] = GridSpaceConfig(
                name: scYAML.name,
                layouts: scYAML.layouts,
                defaultLayout: scYAML.defaultLayout,
                autoApply: scYAML.autoApply ?? false
            )
        }
        spaces = result
    }

    private func parseAppRules(from dict: [String: Any]) throws {
        if let rulesRaw = dict["appRules"] {
            let yamlStr = try Yams.dump(object: rulesRaw)
            let rulesYAML = try YAMLDecoder().decode([GridAppRuleYAML].self, from: yamlStr)
            appRules = rulesYAML.map { r in
                GridAppRule(
                    app: r.app,
                    preferredCell: r.preferredCell,
                    layouts: r.layouts,
                    float: r.float ?? false,
                    locked: r.locked ?? false,
                    preferredStackMode: r.preferredStackMode.flatMap { GridStackMode(rawValue: $0) }
                )
            }
        } else {
            appRules = []
        }

        // Append built-in rules that aren't overridden by user config
        appendBuiltinAppRules()
    }

    // Built-in app rules appended after user config parsing.
    // User rules take precedence: if a rule with the same `app` already exists, the builtin is skipped.
    private func appendBuiltinAppRules() {
        let builtinRules: [GridAppRule] = [
            GridAppRule(
                app: "com.thegrid.notify",
                preferredCell: "notify",
                float: false,
                locked: true,
                preferredStackMode: nil
            ),
        ]

        let existingApps = Set(appRules.map { $0.app })
        for builtin in builtinRules {
            if !existingApps.contains(builtin.app) {
                appRules.append(builtin)
            }
        }
    }

    private func parseServerFields(from dict: [String: Any]) {
        // Window blacklist (support both naming conventions)
        if let bl = dict["window_blacklist"] as? [String] {
            windowBlacklist = bl
        } else if let bl = dict["windowBlacklist"] as? [String] {
            windowBlacklist = bl
        } else {
            windowBlacklist = []
        }

        // Picker section
        pickerActions = []
        zoxidePath = nil
        if let pickerDict = dict["picker"] as? [String: Any] {
            if let actionsRaw = pickerDict["actions"] {
                do {
                    let yamlStr = try Yams.dump(object: actionsRaw)
                    pickerActions = try YAMLDecoder().decode([ActionDef].self, from: yamlStr)
                } catch {
                    JSONLogger.shared.log("grid.cfg.warn", msg: "failed to parse picker actions", data: ["err": "\(error)"])
                }
            }
            if let zp = pickerDict["zoxide_path"] as? String {
                zoxidePath = zp
            } else if let zp = pickerDict["zoxidePath"] as? String {
                zoxidePath = zp
            }
        }
    }

    private func parseNotifications(from dict: [String: Any]) {
        guard let raw = dict["notifications"] as? [String: Any] else {
            // No notifications section -- reset to defaults (supports removing config)
            notifications = GridNotificationsConfig()
            return
        }

        do {
            let yamlStr = try Yams.dump(object: raw)
            let decoded = try YAMLDecoder().decode(NotificationsYAML.self, from: yamlStr)

            var config = GridNotificationsConfig()

            // Theme colors: pass raw [String: String] dict directly to NotificationPanelTheme
            if let themeDict = decoded.theme {
                config.themeColors = themeDict
            }

            // Max count: 0 means unlimited; negative values are ignored
            if let mc = decoded.maxCount, mc > 0 {
                config.maxCount = mc
            }

            // Event rules: map from YAML structs to runtime value types
            if let rulesRaw = decoded.eventRules {
                for (eventName, ruleYAML) in rulesRaw {
                    let priority = GridNotificationPriority(rawValue: ruleYAML.priority ?? "normal")
                        ?? .normal
                    config.eventRules[eventName] = EventNotificationRule(
                        title: ruleYAML.title,
                        body: ruleYAML.body ?? "",
                        priority: priority
                    )
                }
            }

            // File watcher path: expand tilde so the watcher receives an absolute path
            if let fw = decoded.fileWatcher {
                config.watcherPath = expandTilde(fw.path ?? "")
                config.watcherSourceLabel = fw.sourceLabel ?? "pipe"
            }

            notifications = config
            JSONLogger.shared.log("grid.cfg.notifications", data: [
                "event_rules": config.eventRules.count,
                "watcher_path": config.watcherPath,
                "max_count": config.maxCount
            ])
        } catch {
            // Log and keep defaults -- malformed notifications section should not crash server
            JSONLogger.shared.log("err.grid.cfg.notifications", msg: "failed to parse", data: ["err": "\(error)"])
            notifications = GridNotificationsConfig()
        }
    }

    // MARK: - Layout Conversion

    private func convertLayoutYAMLToDef(_ lc: GridLayoutYAML) throws -> GridLayoutDef {
        // Parse columns
        let columns = try lc.grid.columns.map { try GridTrackSize.parse($0) }
        let rows = try lc.grid.rows.map { try GridTrackSize.parse($0) }

        // Parse cells
        var cells: [GridCellDef]
        if let areas = lc.areas, !areas.isEmpty {
            cells = areasToGridCells(areas: areas)
        } else if let cellYAMLs = lc.cells {
            cells = try cellYAMLs.map { try convertCellYAMLToDef($0) }
        } else {
            cells = []
        }

        // Parse layout-level padding
        let layoutPadding = try GridPadding.parse(lc.padding?.value)

        // Parse layout-level windowSpacing
        var layoutWindowSpacing: GridPaddingValue?
        if let ws = lc.windowSpacing?.value {
            layoutWindowSpacing = try GridPaddingValue.parse(ws)
        }

        // Map cellModes
        var cellModes: [String: GridStackMode] = [:]
        if let modes = lc.cellModes {
            for (k, v) in modes {
                if let sm = GridStackMode(rawValue: v) {
                    cellModes[k] = sm
                }
            }
        }

        return GridLayoutDef(
            id: lc.id,
            name: lc.name ?? "",
            description: lc.description ?? "",
            columns: columns,
            rows: rows,
            cells: cells,
            cellModes: cellModes,
            padding: layoutPadding,
            windowSpacing: layoutWindowSpacing
        )
    }

    private func convertCellYAMLToDef(_ cell: GridCellYAML) throws -> GridCellDef {
        let (colStart, colEnd) = try parseSpan(cell.column)
        let (rowStart, rowEnd) = try parseSpan(cell.row)

        var stackMode: GridStackMode?
        if let sm = cell.stackMode {
            stackMode = GridStackMode(rawValue: sm)
        }

        var border: GridCellBorderConfig?
        if let b = cell.border {
            border = GridCellBorderConfig(
                activeCellColor: b.activeCellColor,
                inactiveColor: b.inactiveColor,
                style: b.style
            )
        }

        // Parse cell-level padding
        let cellPadding = try GridPadding.parse(cell.padding?.value)

        // Parse cell-level windowSpacing
        var cellWindowSpacing: GridPaddingValue?
        if let ws = cell.windowSpacing?.value {
            cellWindowSpacing = try GridPaddingValue.parse(ws)
        }

        return GridCellDef(
            id: cell.id,
            columnStart: colStart,
            columnEnd: colEnd,
            rowStart: rowStart,
            rowEnd: rowEnd,
            stackMode: stackMode,
            padding: cellPadding,
            windowSpacing: cellWindowSpacing,
            border: border
        )
    }
}
