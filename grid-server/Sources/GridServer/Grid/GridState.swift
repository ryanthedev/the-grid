import Foundation

// MARK: - Codable Model Structs (internal, match Go JSON format)

struct GridRuntimeStateData: Codable {
    var version: Int = 1
    var spaces: [String: GridSpaceStateData] = [:]
    var displaySpaces: [String: [String]] = [:]
    var lastUpdated: Date = Date()
}

struct GridSpaceStateData: Codable {
    var spaceId: String = ""
    var currentLayoutId: String = ""
    var layoutIndex: Int = 0
    var cells: [String: GridCellStateData] = [:]
    var focusedCell: String = ""
    var focusedWindow: Int = 0
    var columnRatios: [Double]?
    var rowRatios: [Double]?

    enum CodingKeys: String, CodingKey {
        case spaceId, currentLayoutId, layoutIndex, cells
        case focusedCell, focusedWindow, columnRatios, rowRatios
    }
}

struct GridCellStateData: Codable {
    var cellId: String = ""
    var windows: [UInt32] = []
    var splitRatios: [Double] = []
    var stackMode: GridStackMode?
    var lastFocusedIdx: Int = 0
    var lastFocusedWid: UInt32 = 0
    var prevFocusedWid: UInt32 = 0

    enum CodingKeys: String, CodingKey {
        case cellId, windows, splitRatios, stackMode
        case lastFocusedIdx, lastFocusedWid, prevFocusedWid
    }

    init() {}

    init(cellId: String) {
        self.cellId = cellId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cellId = try container.decodeIfPresent(String.self, forKey: .cellId) ?? ""
        windows = try container.decodeIfPresent([UInt32].self, forKey: .windows) ?? []
        splitRatios = try container.decodeIfPresent([Double].self, forKey: .splitRatios) ?? []
        lastFocusedIdx = try container.decodeIfPresent(Int.self, forKey: .lastFocusedIdx) ?? 0
        lastFocusedWid = try container.decodeIfPresent(UInt32.self, forKey: .lastFocusedWid) ?? 0
        prevFocusedWid = try container.decodeIfPresent(UInt32.self, forKey: .prevFocusedWid) ?? 0

        let modeStr = try container.decodeIfPresent(String.self, forKey: .stackMode) ?? ""
        if modeStr.isEmpty {
            stackMode = nil
        } else {
            stackMode = GridStackMode(rawValue: modeStr)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cellId, forKey: .cellId)
        try container.encode(windows, forKey: .windows)
        try container.encode(splitRatios, forKey: .splitRatios)
        try container.encode(lastFocusedIdx, forKey: .lastFocusedIdx)
        try container.encode(lastFocusedWid, forKey: .lastFocusedWid)
        try container.encode(prevFocusedWid, forKey: .prevFocusedWid)

        if let mode = stackMode {
            try container.encode(mode.rawValue, forKey: .stackMode)
        } else {
            try container.encode("", forKey: .stackMode)
        }
    }
}

// MARK: - GridState Actor

actor GridState {
    private var spaces: [String: GridSpaceStateData] = [:]
    private var displaySpaces: [String: [String]] = [:]
    private var lastUpdated: Date = Date()

    private let statePath: String
    private var saveTask: Task<Void, Never>?
    private var isDirty: Bool = false
    private let debounceInterval: Duration = .milliseconds(500)

    private static let stateVersion = 1

    // MARK: - Initialization + Load

    init() {
        statePath = "\(XDG.stateHome)/thegrid/state.json"
    }

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: statePath) else {
            jlog("grid.state.load.new")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateStr = try container.decode(String.self)
                if let date = GridState.dateFormatter.date(from: dateStr) {
                    return date
                }
                if let date = GridState.dateFormatterFallback.date(from: dateStr) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "cannot parse date: \(dateStr)"
                )
            }
            let decoded = try decoder.decode(GridRuntimeStateData.self, from: data)
            spaces = decoded.spaces
            displaySpaces = decoded.displaySpaces
            lastUpdated = decoded.lastUpdated

            for key in spaces.keys {
                if spaces[key]?.cells == nil {
                    spaces[key]?.cells = [:]
                }
            }

            jlog("grid.state.load", data: ["spaceCount": spaces.count])
        } catch {
            jlog("err.grid.state.load", msg: "\(error)")
        }
    }

    // MARK: - Date Formatters

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormatterFallback: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Persistence (debounced)

    private func markDirty() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: debounceInterval)
                self.persistNow()
            } catch {
                // Cancelled — a newer save is pending
            }
        }
    }

    private func persistNow() {
        guard isDirty else { return }
        isDirty = false
        lastUpdated = Date()

        let stateData = GridRuntimeStateData(
            version: GridState.stateVersion,
            spaces: spaces,
            displaySpaces: displaySpaces,
            lastUpdated: lastUpdated
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                let str = GridState.dateFormatter.string(from: date)
                try container.encode(str)
            }
            let data = try encoder.encode(stateData)

            let fm = FileManager.default
            let dir = (statePath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let tmpPath = statePath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tmpPath))
            // POSIX rename atomically replaces destination
            if rename(tmpPath, statePath) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            jlog("grid.state.save")
        } catch {
            jlog("err.grid.state.save", msg: "\(error)")
            isDirty = true
        }
    }

    func flush() {
        if isDirty {
            persistNow()
        }
    }

    func reset() {
        spaces = [:]
        displaySpaces = [:]
        isDirty = true
        persistNow()
    }

    // MARK: - Space Access

    @discardableResult
    func getSpace(_ spaceID: String) -> GridSpaceStateData {
        if let space = spaces[spaceID] {
            return space
        }
        var space = GridSpaceStateData()
        space.spaceId = spaceID
        spaces[spaceID] = space
        return space
    }

    func getSpaceReadOnly(_ spaceID: String) -> GridSpaceStateData? {
        return spaces[spaceID]
    }

    func removeSpace(_ spaceID: String) {
        spaces.removeValue(forKey: spaceID)
        markDirty()
    }

    // MARK: - Space ID Migration (sleep/wake)

    func migrateSpaceIDs(currentDisplaySpaces: [String: [String]]) -> Bool {
        var migrated = false

        for (displayUUID, newSpaceList) in currentDisplaySpaces {
            if displayUUID.isEmpty || newSpaceList.isEmpty {
                continue
            }

            let oldSpaceList = displaySpaces[displayUUID] ?? []
            let limit = min(oldSpaceList.count, newSpaceList.count)

            for i in 0..<limit {
                let oldSpaceID = oldSpaceList[i]
                let newSpaceID = newSpaceList[i]

                if oldSpaceID.isEmpty || newSpaceID.isEmpty || oldSpaceID == newSpaceID {
                    continue
                }

                if var oldState = spaces[oldSpaceID], hasSignificantState(oldState) {
                    oldState.spaceId = newSpaceID
                    spaces[newSpaceID] = oldState
                    spaces.removeValue(forKey: oldSpaceID)
                    migrated = true

                    jlog("state.space_migrated", data: [
                        "display": displayUUID,
                        "old": oldSpaceID,
                        "new": newSpaceID,
                        "position": i,
                    ])
                }
            }

            displaySpaces[displayUUID] = newSpaceList
        }

        if migrated {
            markDirty()
        }
        return migrated
    }

    private func hasSignificantState(_ space: GridSpaceStateData) -> Bool {
        return !space.currentLayoutId.isEmpty || !space.cells.isEmpty
    }

    // MARK: - Layout Cycling

    func setCurrentLayout(spaceID: String, layoutID: String, layoutIndex: Int) {
        var space = getSpace(spaceID)
        space.currentLayoutId = layoutID
        space.layoutIndex = layoutIndex
        space.cells = [:]
        space.focusedCell = ""
        space.focusedWindow = 0
        space.columnRatios = nil
        space.rowRatios = nil
        spaces[spaceID] = space
        markDirty()
    }

    func cycleLayout(spaceID: String, availableLayouts: [String]) -> String {
        if availableLayouts.isEmpty {
            return spaces[spaceID]?.currentLayoutId ?? ""
        }
        let space = getSpace(spaceID)
        let newIndex = (space.layoutIndex + 1) % availableLayouts.count
        let newLayoutID = availableLayouts[newIndex]
        setCurrentLayout(spaceID: spaceID, layoutID: newLayoutID, layoutIndex: newIndex)
        return newLayoutID
    }

    func previousLayout(spaceID: String, availableLayouts: [String]) -> String {
        if availableLayouts.isEmpty {
            return spaces[spaceID]?.currentLayoutId ?? ""
        }
        let space = getSpace(spaceID)
        let newIndex = (space.layoutIndex - 1 + availableLayouts.count) % availableLayouts.count
        let newLayoutID = availableLayouts[newIndex]
        setCurrentLayout(spaceID: spaceID, layoutID: newLayoutID, layoutIndex: newIndex)
        return newLayoutID
    }

    func getCurrentLayout(spaceID: String) -> String {
        return spaces[spaceID]?.currentLayoutId ?? ""
    }

    // MARK: - Window Assignment

    func assignWindow(_ windowID: UInt32, toCellID cellID: String, inSpace spaceID: String) {
        var space = getSpace(spaceID)
        var cell = space.cells[cellID] ?? GridCellStateData(cellId: cellID)

        if cell.windows.contains(windowID) {
            return
        }

        removeWindowInternal(windowID, from: &space)

        cell.windows.append(windowID)
        cell.lastFocusedIdx = cell.windows.count - 1
        cell.lastFocusedWid = windowID
        cell.splitRatios = equalRatios(cell.windows.count)
        space.cells[cellID] = cell
        spaces[spaceID] = space
        markDirty()
    }

    func prependWindow(_ windowID: UInt32, toCellID cellID: String, inSpace spaceID: String) {
        var space = getSpace(spaceID)
        var cell = space.cells[cellID] ?? GridCellStateData(cellId: cellID)

        if !cell.windows.isEmpty && cell.windows[0] == windowID {
            return
        }

        removeWindowInternal(windowID, from: &space)
        cell = space.cells[cellID] ?? GridCellStateData(cellId: cellID)

        cell.windows.insert(windowID, at: 0)
        cell.lastFocusedIdx = 0
        cell.lastFocusedWid = windowID
        cell.splitRatios = equalRatios(cell.windows.count)
        space.cells[cellID] = cell
        spaces[spaceID] = space
        markDirty()
    }

    func insertWindow(_ windowID: UInt32, atIndex index: Int, inCellID cellID: String, inSpace spaceID: String) {
        var space = getSpace(spaceID)

        removeWindowInternal(windowID, from: &space)
        var cell = space.cells[cellID] ?? GridCellStateData(cellId: cellID)

        let clampedIndex = max(0, min(index, cell.windows.count))
        cell.windows.insert(windowID, at: clampedIndex)
        cell.lastFocusedIdx = clampedIndex
        cell.lastFocusedWid = windowID
        cell.splitRatios = equalRatios(cell.windows.count)
        space.cells[cellID] = cell
        spaces[spaceID] = space
        markDirty()
    }

    func removeWindow(_ windowID: UInt32, fromSpace spaceID: String) {
        guard var space = spaces[spaceID] else { return }

        for (cellID, var cell) in space.cells {
            guard let idx = cell.windows.firstIndex(of: windowID) else { continue }

            cell.windows.remove(at: idx)

            if cell.windows.isEmpty {
                cell.lastFocusedIdx = 0
                cell.lastFocusedWid = 0
                cell.prevFocusedWid = 0
            } else {
                if cell.lastFocusedIdx >= cell.windows.count {
                    cell.lastFocusedIdx = cell.windows.count - 1
                }
                if cell.lastFocusedWid == windowID {
                    cell.lastFocusedWid = 0
                    if cell.prevFocusedWid != 0 {
                        for (j, wid) in cell.windows.enumerated() {
                            if wid == cell.prevFocusedWid {
                                cell.lastFocusedWid = cell.prevFocusedWid
                                cell.lastFocusedIdx = j
                                break
                            }
                        }
                    }
                    cell.prevFocusedWid = 0
                }
                if cell.prevFocusedWid == windowID {
                    cell.prevFocusedWid = 0
                }
            }

            if cell.windows.isEmpty {
                cell.splitRatios = []
            } else {
                cell.splitRatios = equalRatios(cell.windows.count)
            }

            // Fix space-level focus if the removed window's cell was focused
            if space.focusedCell == cellID {
                if cell.windows.isEmpty {
                    space.focusedCell = ""
                    space.focusedWindow = 0
                } else {
                    space.focusedWindow = cell.lastFocusedIdx
                }
            }

            space.cells[cellID] = cell
            spaces[spaceID] = space
            markDirty()
            return
        }
    }

    func removeWindowFromAllSpaces(_ windowID: UInt32) {
        for spaceID in spaces.keys {
            removeWindow(windowID, fromSpace: spaceID)
        }
    }

    private func removeWindowInternal(_ windowID: UInt32, from space: inout GridSpaceStateData) {
        for (cellID, var cell) in space.cells {
            guard let idx = cell.windows.firstIndex(of: windowID) else { continue }

            cell.windows.remove(at: idx)

            if cell.windows.isEmpty {
                cell.lastFocusedIdx = 0
                cell.lastFocusedWid = 0
                cell.prevFocusedWid = 0
            } else {
                if cell.lastFocusedIdx >= cell.windows.count {
                    cell.lastFocusedIdx = cell.windows.count - 1
                }
                if cell.lastFocusedWid == windowID {
                    cell.lastFocusedWid = 0
                    if cell.prevFocusedWid != 0 {
                        for (j, wid) in cell.windows.enumerated() {
                            if wid == cell.prevFocusedWid {
                                cell.lastFocusedWid = cell.prevFocusedWid
                                cell.lastFocusedIdx = j
                                break
                            }
                        }
                    }
                    cell.prevFocusedWid = 0
                }
                if cell.prevFocusedWid == windowID {
                    cell.prevFocusedWid = 0
                }
            }

            if cell.windows.isEmpty {
                cell.splitRatios = []
            } else {
                cell.splitRatios = equalRatios(cell.windows.count)
            }

            space.cells[cellID] = cell
            return
        }
    }

    // MARK: - Window Queries

    func getWindowCell(windowID: UInt32, inSpace spaceID: String) -> String? {
        guard let space = spaces[spaceID] else { return nil }
        for (cellID, cell) in space.cells {
            if cell.windows.contains(windowID) {
                return cellID
            }
        }
        return nil
    }

    // Find which space contains a window (searches all spaces)
    func findSpaceContaining(windowID: UInt32) -> String? {
        for (spaceID, space) in spaces {
            for (_, cell) in space.cells {
                if cell.windows.contains(windowID) {
                    return spaceID
                }
            }
        }
        return nil
    }

    func getCellWindows(spaceID: String, cellID: String) -> [UInt32] {
        guard let space = spaces[spaceID],
              let cell = space.cells[cellID] else {
            return []
        }
        return Array(cell.windows)
    }

    func getAllWindowIDs() -> [UInt32] {
        var seen = Set<UInt32>()
        var ids: [UInt32] = []
        for space in spaces.values {
            for cell in space.cells.values {
                for wid in cell.windows {
                    if seen.insert(wid).inserted {
                        ids.append(wid)
                    }
                }
            }
        }
        return ids
    }

    func getWindowAssignments(spaceID: String) -> [String: [UInt32]] {
        guard let space = spaces[spaceID] else { return [:] }
        var assignments: [String: [UInt32]] = [:]
        for (cellID, cell) in space.cells {
            if !cell.windows.isEmpty {
                assignments[cellID] = Array(cell.windows)
            }
        }
        return assignments
    }

    func setWindowAssignments(spaceID: String, assignments: [String: [UInt32]]) {
        var space = getSpace(spaceID)
        let existingCells = space.cells

        space.cells = [:]

        for (cellID, windowIDs) in assignments {
            var cell = GridCellStateData(cellId: cellID)
            cell.windows = windowIDs

            if let existingCell = existingCells[cellID] {
                cell.stackMode = existingCell.stackMode

                if existingCell.lastFocusedIdx >= 0 && existingCell.lastFocusedIdx < existingCell.windows.count {
                    let focusedWID = existingCell.windows[existingCell.lastFocusedIdx]
                    cell.lastFocusedIdx = 0
                    for (i, wid) in windowIDs.enumerated() {
                        if wid == focusedWID {
                            cell.lastFocusedIdx = i
                            break
                        }
                    }
                } else {
                    cell.lastFocusedIdx = 0
                }

                if !existingCell.splitRatios.isEmpty {
                    if existingCell.splitRatios.count == windowIDs.count {
                        cell.splitRatios = existingCell.splitRatios
                    } else {
                        cell.splitRatios = adjustRatiosForCount(existingCell.splitRatios, newCount: windowIDs.count)
                    }
                } else {
                    cell.splitRatios = equalRatios(windowIDs.count)
                }
            } else {
                cell.splitRatios = equalRatios(windowIDs.count)
            }

            space.cells[cellID] = cell
        }

        spaces[spaceID] = space
        markDirty()
    }

    // MARK: - Focus Tracking

    func setFocus(spaceID: String, cellID: String, windowIndex: Int) {
        var space = getSpace(spaceID)
        space.focusedCell = cellID
        space.focusedWindow = windowIndex

        if var cell = space.cells[cellID] {
            cell.lastFocusedIdx = windowIndex
            if windowIndex >= 0 && windowIndex < cell.windows.count {
                let newWID = cell.windows[windowIndex]
                if cell.lastFocusedWid != 0 && cell.lastFocusedWid != newWID {
                    cell.prevFocusedWid = cell.lastFocusedWid
                }
                cell.lastFocusedWid = newWID
            }
            space.cells[cellID] = cell
        }

        spaces[spaceID] = space
        markDirty()
    }

    func getFocusedWindow(spaceID: String) -> UInt32 {
        guard let space = spaces[spaceID] else { return 0 }
        if space.focusedCell.isEmpty { return 0 }
        guard let cell = space.cells[space.focusedCell],
              !cell.windows.isEmpty else { return 0 }

        if space.focusedWindow >= 0 && space.focusedWindow < cell.windows.count {
            return cell.windows[space.focusedWindow]
        }
        return cell.windows[0]
    }

    func getFocusedCell(spaceID: String) -> String? {
        guard let space = spaces[spaceID] else { return nil }
        if space.focusedCell.isEmpty { return nil }
        return space.focusedCell
    }

    // MARK: - Cell Stack Mode

    func getCellStackMode(spaceID: String, cellID: String) -> GridStackMode? {
        guard let space = spaces[spaceID],
              let cell = space.cells[cellID] else {
            return nil
        }
        return cell.stackMode
    }

    func setCellStackMode(spaceID: String, cellID: String, mode: GridStackMode?) {
        var space = getSpace(spaceID)
        var cell = space.cells[cellID] ?? GridCellStateData(cellId: cellID)
        cell.stackMode = mode
        space.cells[cellID] = cell
        spaces[spaceID] = space
        markDirty()
    }

    // MARK: - Split Ratios

    func getCellSplitRatios(spaceID: String, cellID: String) -> [Double] {
        guard let space = spaces[spaceID],
              let cell = space.cells[cellID] else {
            return []
        }
        return Array(cell.splitRatios)
    }

    func setCellSplitRatios(spaceID: String, cellID: String, ratios: [Double]) {
        var space = getSpace(spaceID)
        var cell = space.cells[cellID] ?? GridCellStateData(cellId: cellID)
        cell.splitRatios = normalizeRatios(ratios)
        space.cells[cellID] = cell
        spaces[spaceID] = space
        markDirty()
    }

    // MARK: - Column/Row Ratios

    func getColumnRatios(spaceID: String) -> [Double]? {
        return spaces[spaceID]?.columnRatios
    }

    func setColumnRatios(spaceID: String, ratios: [Double]) {
        var space = getSpace(spaceID)
        space.columnRatios = normalizeRatios(ratios)
        spaces[spaceID] = space
        markDirty()
    }

    func getRowRatios(spaceID: String) -> [Double]? {
        return spaces[spaceID]?.rowRatios
    }

    func setRowRatios(spaceID: String, ratios: [Double]) {
        var space = getSpace(spaceID)
        space.rowRatios = normalizeRatios(ratios)
        spaces[spaceID] = space
        markDirty()
    }

    // Clear column and row ratios to nil (layout defaults)
    func clearTrackRatios(spaceID: String) {
        guard var space = spaces[spaceID] else { return }
        space.columnRatios = nil
        space.rowRatios = nil
        spaces[spaceID] = space
        markDirty()
    }

    // MARK: - Query Helpers

    func hasState(spaceID: String) -> Bool {
        guard let space = spaces[spaceID] else { return false }
        return !space.currentLayoutId.isEmpty || !space.cells.isEmpty
    }

    func summary() -> [String: Any] {
        var spaceSummaries: [String: Any] = [:]
        for (spaceID, space) in spaces {
            var windowCount = 0
            for cell in space.cells.values {
                windowCount += cell.windows.count
            }
            spaceSummaries[spaceID] = [
                "currentLayout": space.currentLayoutId,
                "cellCount": space.cells.count,
                "windowCount": windowCount,
                "focusedCell": space.focusedCell,
            ] as [String: Any]
        }
        return [
            "version": GridState.stateVersion,
            "lastUpdated": lastUpdated,
            "spaceCount": spaces.count,
            "spaces": spaceSummaries,
        ] as [String: Any]
    }

    // MARK: - Export

    func exportState() -> GridRuntimeStateData {
        return GridRuntimeStateData(
            version: GridState.stateVersion,
            spaces: spaces,
            displaySpaces: displaySpaces,
            lastUpdated: lastUpdated
        )
    }

    // MARK: - Ratio Utilities (private)

    private func equalRatios(_ n: Int) -> [Double] {
        if n <= 0 { return [] }
        let ratio = 1.0 / Double(n)
        return Array(repeating: ratio, count: n)
    }

    private func normalizeRatios(_ ratios: [Double]) -> [Double] {
        if ratios.isEmpty { return [] }
        let sum = ratios.reduce(0.0, +)
        if sum == 0 { return equalRatios(ratios.count) }
        return ratios.map { $0 / sum }
    }

    private func adjustRatiosForCount(_ ratios: [Double], newCount: Int) -> [Double] {
        if newCount <= 0 { return [] }
        if ratios.isEmpty { return equalRatios(newCount) }
        if ratios.count == newCount { return normalizeRatios(ratios) }

        if newCount < ratios.count {
            let kept = Array(ratios.prefix(newCount))
            return normalizeRatios(kept)
        }

        // Growing
        var newRatios = [Double](repeating: 0, count: newCount)
        let addedCount = newCount - ratios.count
        let sharePerNew = 1.0 / Double(newCount)
        let totalTaken = sharePerNew * Double(addedCount)
        let scale = 1.0 - totalTaken

        for i in 0..<ratios.count {
            newRatios[i] = ratios[i] * scale
        }
        for i in ratios.count..<newCount {
            newRatios[i] = sharePerNew
        }

        return normalizeRatios(newRatios)
    }
}
