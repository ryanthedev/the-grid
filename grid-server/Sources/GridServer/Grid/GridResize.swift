import Foundation

// MARK: - Resize Errors

enum GridResizeError: Error, LocalizedError {
    case noLayout
    case noFocusedCell
    case needAtLeastTwoWindows
    case needAtLeastTwoFlexTracks
    case cellNotFoundInLayout(String)
    case atEdgeOfLayout(String)

    var errorDescription: String? {
        switch self {
        case .noLayout: return "no layout applied"
        case .noFocusedCell: return "no focused cell"
        case .needAtLeastTwoWindows: return "need at least 2 windows to resize"
        case .needAtLeastTwoFlexTracks: return "need at least 2 flexible tracks to resize cells"
        case .cellNotFoundInLayout(let id): return "cell \(id) not found in layout"
        case .atEdgeOfLayout(let dir): return "cannot resize in direction \(dir): at edge of layout"
        }
    }
}

// MARK: - GridResize

class GridResize {

    // Dependencies (weak references, set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var gridApply: GridApply?
    private weak var gridFocus: GridFocus?
    private weak var stateManager: StateManager?

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        gridApply: GridApply,
        gridFocus: GridFocus,
        stateManager: StateManager
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.gridApply = gridApply
        self.gridFocus = gridFocus
        self.stateManager = stateManager
        jlog("resize.init")
    }

    // ============================================================
    // adjustFocusedSplit: grow/shrink split ratio between stacked
    // windows in the focused cell
    // ============================================================

    func adjustFocusedSplit(spaceID: String, delta: Double) async throws {
        guard let gridState = gridState,
              let gridApply = gridApply else {
            throw GridResizeError.noLayout
        }

        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridResizeError.noLayout
        }

        let focusedCell = spaceState.focusedCell
        guard !focusedCell.isEmpty else {
            throw GridResizeError.noFocusedCell
        }

        guard let cell = spaceState.cells[focusedCell],
              cell.windows.count >= 2 else {
            throw GridResizeError.needAtLeastTwoWindows
        }

        // Determine boundary to adjust based on focused window index
        var idx = spaceState.focusedWindow
        if idx < 0 || idx >= cell.windows.count {
            idx = 0
        }

        // Get current split ratios (or initialize equal if wrong length)
        var ratios = cell.splitRatios
        if ratios.count != cell.windows.count {
            ratios = GridLayout.equalRatios(cell.windows.count)
        }

        // Resolve the boundary index and effective delta, negating delta when the
        // focused window is last so that "grow" always expands the focused window.
        let (boundaryIndex, effectiveDelta) = GridResize.resolveBoundaryAndDelta(
            idx: idx,
            ratios: ratios,
            delta: delta
        )

        // Sole-window cell: no boundary to adjust.
        guard boundaryIndex >= 0 else {
            throw GridResizeError.needAtLeastTwoWindows
        }

        // Adjust the split ratio at this boundary
        let result = GridLayout.adjustSplitRatio(
            ratios: ratios,
            index: boundaryIndex,
            delta: effectiveDelta,
            minRatio: GridLayout.minimumRatio
        )
        switch result {
        case .success(let newRatios):
            await gridState.setCellSplitRatios(spaceID: spaceID, cellID: focusedCell, ratios: newRatios)
        case .failure(let error):
            throw error
        }

        // Reapply layout to reposition windows
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)

        jlog("resize.split.done")
    }

    // ============================================================
    // resolveBoundaryAndDelta: pure helper for split-boundary selection.
    //
    // Returns (boundaryIndex, effectiveDelta):
    //   - boundaryIndex: the boundary to adjust (between idx and idx+1).
    //     Clamped to ratios.count-2 when idx is the last window.
    //     Returns -1 for a sole-window cell (no valid boundary).
    //   - effectiveDelta: delta, negated when the boundary was clamped.
    //     Negation ensures "grow" always expands the focused window:
    //     adjustSplitRatio adds effectiveDelta to ratios[boundaryIndex] and
    //     subtracts from ratios[boundaryIndex+1]. When the last window is
    //     focused, boundaryIndex points to the window BEFORE it, so delta
    //     must be negated to shift the split in the correct direction.
    // ============================================================

    static func resolveBoundaryAndDelta(
        idx: Int,
        ratios: [Double],
        delta: Double
    ) -> (boundaryIndex: Int, effectiveDelta: Double) {
        guard ratios.count >= 2 else {
            // Sole-window cell: no valid boundary
            return (-1, delta)
        }
        if idx < ratios.count - 1 {
            // Not the last window: boundary is directly after focused index
            return (idx, delta)
        }
        // Last window: clamp to the boundary before it and negate delta
        return (ratios.count - 2, -delta)
    }

    // ============================================================
    // resetSplits: reset split ratios to equal for focused cell
    // or all cells
    // ============================================================

    func resetSplits(spaceID: String, allCells: Bool) async throws {
        guard let gridState = gridState,
              let gridApply = gridApply else {
            throw GridResizeError.noLayout
        }

        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridResizeError.noLayout
        }

        if allCells {
            // Reset every cell's splits to equal
            for (cellID, cell) in spaceState.cells {
                let equalRatios = GridLayout.equalRatios(cell.windows.count)
                await gridState.setCellSplitRatios(spaceID: spaceID, cellID: cellID, ratios: equalRatios)
            }
        } else {
            // Reset only focused cell
            let focusedCell = spaceState.focusedCell
            guard !focusedCell.isEmpty else {
                throw GridResizeError.noFocusedCell
            }

            guard let cell = spaceState.cells[focusedCell] else {
                throw GridResizeError.noFocusedCell
            }

            let equalRatios = GridLayout.equalRatios(cell.windows.count)
            await gridState.setCellSplitRatios(spaceID: spaceID, cellID: focusedCell, ratios: equalRatios)
        }

        // Reapply layout
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)

        jlog("resize.splits_reset.done")
    }

    // ============================================================
    // adjustCellBoundary: grow/shrink the focused cell's edge in
    // a direction by adjusting column or row track ratios
    // ============================================================

    func adjustCellBoundary(spaceID: String, direction: GridDirection, delta: Double) async throws {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let gridApply = gridApply else {
            throw GridResizeError.noLayout
        }

        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridResizeError.noLayout
        }

        let focusedCell = spaceState.focusedCell
        guard !focusedCell.isEmpty else {
            throw GridResizeError.noFocusedCell
        }

        // Look up layout definition to get tracks and cell grid positions
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: spaceState.currentLayoutId) }

        // Find the focused cell's definition in the layout
        guard let cellDef = layoutDef.cells.first(where: { $0.id == focusedCell }) else {
            throw GridResizeError.cellNotFoundInLayout(focusedCell)
        }

        // Determine axis: left/right = columns, up/down = rows
        let isColumn = direction == .left || direction == .right
        let isGrowing = direction == .right || direction == .down

        // Select the relevant tracks and current ratios
        let tracks: [GridTrackSize]
        var currentRatios: [Double]?
        let trackStart: Int
        let trackEnd: Int

        if isColumn {
            tracks = layoutDef.columns
            currentRatios = await gridState.getColumnRatios(spaceID: spaceID)
            // Convert to 0-indexed
            trackStart = cellDef.columnStart - 1
            // End line is after last column
            trackEnd = cellDef.columnEnd - 2
        } else {
            tracks = layoutDef.rows
            currentRatios = await gridState.getRowRatios(spaceID: spaceID)
            trackStart = cellDef.rowStart - 1
            trackEnd = cellDef.rowEnd - 2
        }

        // Need at least 2 flexible tracks to resize between
        let flexCount = GridLayout.countFlexibleTracks(tracks)
        guard flexCount >= 2 else {
            throw GridResizeError.needAtLeastTwoFlexTracks
        }

        // Initialize ratios from track definitions if not set or wrong length
        if currentRatios == nil || currentRatios!.count != flexCount {
            currentRatios = GridLayout.initializeTrackRatios(tracks)
        }

        // Find which boundary to adjust
        let boundaryIndex: Int
        if isGrowing {
            boundaryIndex = GridLayout.getFlexBoundaryIndex(tracks, trackEnd)
        } else {
            boundaryIndex = GridLayout.getFlexBoundaryIndex(tracks, trackStart) - 1
        }

        guard boundaryIndex >= 0 && boundaryIndex < flexCount - 1 else {
            throw GridResizeError.atEdgeOfLayout(direction.rawValue)
        }

        // Compute adjusted delta
        // For left/up: negate delta (adjusting from the other side)
        let adjustDelta = isGrowing ? delta : -delta

        // Get min/max ratio from config
        let minRatio = await MainActor.run { gridConfig.settings.resize.minRatio }
        let maxRatio = await MainActor.run { gridConfig.settings.resize.maxRatio }

        // Adjust the track ratios at this boundary
        let result = GridLayout.adjustSplitRatioWithMax(
            ratios: currentRatios!,
            index: boundaryIndex,
            delta: adjustDelta,
            minRatio: minRatio,
            maxRatio: maxRatio
        )
        switch result {
        case .success(let newRatios):
            // Update state with new track ratios
            if isColumn {
                await gridState.setColumnRatios(spaceID: spaceID, ratios: newRatios)
            } else {
                await gridState.setRowRatios(spaceID: spaceID, ratios: newRatios)
            }
        case .failure(let error):
            throw error
        }

        // Reapply layout
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)

        jlog("resize.cell.done")
    }

    // ============================================================
    // resetCellRatios: reset column and row ratios to layout defaults
    // ============================================================

    func resetCellRatios(spaceID: String) async throws {
        guard let gridState = gridState,
              let gridApply = gridApply else {
            throw GridResizeError.noLayout
        }

        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridResizeError.noLayout
        }

        // Clear track ratios (sets to nil so layout uses default fr distribution)
        await gridState.clearTrackRatios(spaceID: spaceID)

        // Reapply layout
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)

        jlog("resize.ratios_reset.done")
    }
}
