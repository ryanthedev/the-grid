import CoreGraphics

// MARK: - Result Types

struct GridCalculatedLayout: Sendable {
    let layoutID: String
    let screenRect: CGRect
    let gap: Double
    let columnSizes: [Double]
    let rowSizes: [Double]
    let cellBounds: [String: CGRect]
}

struct GridWindowPlacement: Sendable {
    let windowID: UInt32
    let bounds: CGRect
}

// MARK: - Error Type

enum GridLayoutError: Error {
    case needAtLeastTwoWindows
    case invalidSplitIndex(Int)
}

// MARK: - CGRect Extensions

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func overlapsVertically(with other: CGRect) -> Bool {
        minY < other.maxY && maxY > other.minY
    }

    func overlapsHorizontally(with other: CGRect) -> Bool {
        minX < other.maxX && maxX > other.minX
    }

    func overlapArea(with other: CGRect) -> Double {
        let left = Swift.max(self.minX, other.minX)
        let right = Swift.min(self.maxX, other.maxX)
        let top = Swift.max(self.minY, other.minY)
        let bottom = Swift.min(self.maxY, other.maxY)

        if left >= right || top >= bottom {
            return 0
        }

        return Double((right - left) * (bottom - top))
    }
}

// MARK: - Layout Computation

enum GridLayout {

    // MARK: - Constants

    static let minimumRatio: Double = 0.1
    static let defaultResizeAmount: Double = 0.1

    // MARK: - Track Calculation

    static func calculateTracks(
        tracks: [GridTrackSize],
        available: Double,
        gap: Double
    ) -> [Double] {
        calculateTracksWithRatios(tracks: tracks, available: available, gap: gap, ratios: nil)
    }

    static func calculateTracksWithRatios(
        tracks: [GridTrackSize],
        available: Double,
        gap: Double,
        ratios: [Double]?
    ) -> [Double] {
        if tracks.isEmpty { return [] }

        // Subtract total gaps from available space
        let totalGaps = gap * Double(tracks.count - 1)
        var remaining = available - totalGaps

        var sizes = [Double](repeating: 0, count: tracks.count)

        // First pass: allocate fixed tracks, collect flexible track indices
        var totalFr: Double = 0
        var frIndices: [Int] = []

        for (i, track) in tracks.enumerated() {
            switch track.type {
            case .px:
                sizes[i] = track.value
                remaining -= track.value
            case .fr:
                totalFr += track.value
                frIndices.append(i)
            case .minmax:
                sizes[i] = track.min
                remaining -= track.min
                // Max is in fr units
                totalFr += track.max
                frIndices.append(i)
            case .auto:
                sizes[i] = 0
            }
        }

        // Second pass: distribute remaining space to flexible tracks
        if totalFr > 0 && remaining > 0 {
            let useRatioOverrides = ratios != nil
                && ratios!.count == frIndices.count
                && !ratios!.isEmpty

            if useRatioOverrides {
                for (j, i) in frIndices.enumerated() {
                    let track = tracks[i]
                    switch track.type {
                    case .fr:
                        sizes[i] = remaining * ratios![j]
                    case .minmax:
                        sizes[i] = track.min + remaining * ratios![j]
                    default:
                        break
                    }
                }
            } else {
                let frUnit = remaining / totalFr
                for i in frIndices {
                    let track = tracks[i]
                    switch track.type {
                    case .fr:
                        sizes[i] = frUnit * track.value
                    case .minmax:
                        sizes[i] = track.min + frUnit * track.max
                    default:
                        break
                    }
                }
            }
        }

        // Third pass: apply minmax constraints, ensure non-negative
        for (i, track) in tracks.enumerated() {
            if track.type == .minmax && sizes[i] < track.min {
                sizes[i] = track.min
            }
            if sizes[i] < 0 {
                sizes[i] = 0
            }
        }

        return sizes
    }

    // MARK: - Track Positions

    static func calculateTrackPositions(sizes: [Double], gap: Double) -> [Double] {
        var positions = [Double](repeating: 0, count: sizes.count + 1)
        positions[0] = 0

        for (i, size) in sizes.enumerated() {
            positions[i + 1] = positions[i] + size
            if i < sizes.count - 1 {
                positions[i + 1] += gap
            }
        }

        return positions
    }

    // MARK: - Cell Bounds

    static func calculateCellBounds(
        cell: GridCellDef,
        colPositions: [Double],
        rowPositions: [Double],
        colSizes: [Double],
        rowSizes: [Double],
        gap: Double
    ) -> CGRect {
        // Convert 1-indexed to 0-indexed
        let colStart = cell.columnStart - 1
        let colEnd = cell.columnEnd - 1
        let rowStart = cell.rowStart - 1
        let rowEnd = cell.rowEnd - 1

        // Bounds checking
        if colStart < 0 || colEnd > colSizes.count || colStart >= colEnd {
            return .zero
        }
        if rowStart < 0 || rowEnd > rowSizes.count || rowStart >= rowEnd {
            return .zero
        }

        // X position and width
        let x = colPositions[colStart]
        var width: Double = 0
        for i in colStart..<colEnd {
            width += colSizes[i]
            if i < colEnd - 1 {
                width += gap
            }
        }

        // Y position and height
        let y = rowPositions[rowStart]
        var height: Double = 0
        for i in rowStart..<rowEnd {
            height += rowSizes[i]
            if i < rowEnd - 1 {
                height += gap
            }
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Full Layout Calculation

    static func calculateLayout(
        layout: GridLayoutDef,
        screenRect: CGRect,
        gap: Double
    ) -> GridCalculatedLayout {
        calculateLayoutWithRatios(
            layout: layout,
            screenRect: screenRect,
            gap: gap,
            columnRatios: nil,
            rowRatios: nil
        )
    }

    static func calculateLayoutWithRatios(
        layout: GridLayoutDef,
        screenRect: CGRect,
        gap: Double,
        columnRatios: [Double]?,
        rowRatios: [Double]?
    ) -> GridCalculatedLayout {
        // Calculate track sizes
        let columnSizes = calculateTracksWithRatios(
            tracks: layout.columns,
            available: screenRect.width,
            gap: gap,
            ratios: columnRatios
        )
        let rowSizes = calculateTracksWithRatios(
            tracks: layout.rows,
            available: screenRect.height,
            gap: gap,
            ratios: rowRatios
        )

        // Calculate track positions
        let colPositions = calculateTrackPositions(sizes: columnSizes, gap: gap)
        let rowPositions = calculateTrackPositions(sizes: rowSizes, gap: gap)

        // Calculate bounds for each cell
        var cellBounds: [String: CGRect] = [:]
        for cell in layout.cells {
            var bounds = calculateCellBounds(
                cell: cell,
                colPositions: colPositions,
                rowPositions: rowPositions,
                colSizes: columnSizes,
                rowSizes: rowSizes,
                gap: gap
            )
            // Offset by screen position (display offset)
            bounds.origin.x += screenRect.origin.x
            bounds.origin.y += screenRect.origin.y
            cellBounds[cell.id] = bounds
        }

        return GridCalculatedLayout(
            layoutID: layout.id,
            screenRect: screenRect,
            gap: gap,
            columnSizes: columnSizes,
            rowSizes: rowSizes,
            cellBounds: cellBounds
        )
    }

    // MARK: - Cell Queries

    static func getCellAtPoint(
        cellBounds: [String: CGRect],
        point: CGPoint
    ) -> String? {
        for (cellID, bounds) in cellBounds {
            if bounds.contains(point) {
                return cellID
            }
        }
        return nil
    }

    static func getAdjacentCells(
        cellID: String,
        cellBounds: [String: CGRect]
    ) -> [GridDirection: [String]] {
        var result: [GridDirection: [String]] = [
            .left: [],
            .right: [],
            .up: [],
            .down: [],
        ]

        guard let current = cellBounds[cellID] else {
            return result
        }

        let currentCenter = current.center

        for (id, bounds) in cellBounds {
            if id == cellID { continue }

            let otherCenter = bounds.center
            let dx = otherCenter.x - currentCenter.x
            let dy = otherCenter.y - currentCenter.y

            if dx < 0 && current.overlapsVertically(with: bounds) {
                result[.left]!.append(id)
            }
            if dx > 0 && current.overlapsVertically(with: bounds) {
                result[.right]!.append(id)
            }
            if dy < 0 && current.overlapsHorizontally(with: bounds) {
                result[.up]!.append(id)
            }
            if dy > 0 && current.overlapsHorizontally(with: bounds) {
                result[.down]!.append(id)
            }
        }

        // Sort each direction alphabetically for deterministic ordering
        for dir in result.keys {
            result[dir]!.sort()
        }

        return result
    }

    static func sortCellsByPosition(cellBounds: [String: CGRect]) -> [String] {
        let ids = Array(cellBounds.keys)
        return ids.sorted { a, b in
            let boundsA = cellBounds[a]!
            let boundsB = cellBounds[b]!
            if boundsA.origin.y != boundsB.origin.y {
                return boundsA.origin.y < boundsB.origin.y
            }
            return boundsA.origin.x < boundsB.origin.x
        }
    }

    // MARK: - Window Stacking

    static func calculateWindowBounds(
        cellBounds: CGRect,
        windowCount: Int,
        mode: GridStackMode,
        ratios: [Double]?,
        padding: Double
    ) -> [CGRect] {
        if windowCount == 0 { return [] }

        // Use equal ratios if not provided or wrong length
        let resolvedRatios: [Double]
        if let r = ratios, r.count == windowCount {
            resolvedRatios = r
        } else {
            resolvedRatios = equalRatios(windowCount)
        }

        switch mode {
        case .vertical:
            return calculateVerticalStack(
                cellBounds: cellBounds,
                ratios: resolvedRatios,
                padding: padding
            )
        case .horizontal:
            return calculateHorizontalStack(
                cellBounds: cellBounds,
                ratios: resolvedRatios,
                padding: padding
            )
        case .tabs:
            return Array(repeating: cellBounds, count: windowCount)
        }
    }

    private static func calculateVerticalStack(
        cellBounds: CGRect,
        ratios: [Double],
        padding: Double
    ) -> [CGRect] {
        if ratios.isEmpty { return [] }

        let totalPadding = padding * Double(ratios.count - 1)
        let availableHeight = cellBounds.height - totalPadding
        var y = cellBounds.origin.y
        var rects: [CGRect] = []

        for ratio in ratios {
            let height = availableHeight * ratio
            rects.append(CGRect(
                x: cellBounds.origin.x,
                y: y,
                width: cellBounds.width,
                height: height
            ))
            y += height + padding
        }

        return rects
    }

    private static func calculateHorizontalStack(
        cellBounds: CGRect,
        ratios: [Double],
        padding: Double
    ) -> [CGRect] {
        if ratios.isEmpty { return [] }

        let totalPadding = padding * Double(ratios.count - 1)
        let availableWidth = cellBounds.width - totalPadding
        var x = cellBounds.origin.x
        var rects: [CGRect] = []

        for ratio in ratios {
            let width = availableWidth * ratio
            rects.append(CGRect(
                x: x,
                y: cellBounds.origin.y,
                width: width,
                height: cellBounds.height
            ))
            x += width + padding
        }

        return rects
    }

    // MARK: - Ratio Utilities

    static func equalRatios(_ n: Int) -> [Double] {
        if n <= 0 { return [] }
        return Array(repeating: 1.0 / Double(n), count: n)
    }

    static func normalizeRatios(_ ratios: [Double]) -> [Double] {
        if ratios.isEmpty { return [] }
        let sum = ratios.reduce(0, +)
        if sum == 0 { return equalRatios(ratios.count) }
        return ratios.map { $0 / sum }
    }

    static func adjustRatiosForWindowCount(
        _ ratios: [Double],
        newCount: Int
    ) -> [Double] {
        if newCount <= 0 { return [] }
        if ratios.isEmpty { return equalRatios(newCount) }

        let oldCount = ratios.count

        // Same count - just normalize
        if oldCount == newCount {
            return normalizeRatios(ratios)
        }

        // Shrinking: drop last ratios, renormalize
        if newCount < oldCount {
            let truncated = Array(ratios.prefix(newCount))
            return normalizeRatios(truncated)
        }

        // Growing: take equal space from existing for new windows
        let newRatio = 1.0 / Double(newCount)
        let shrinkFactor = Double(oldCount) / Double(newCount)

        var result = [Double](repeating: newRatio, count: newCount)
        for i in 0..<oldCount {
            result[i] = ratios[i] * shrinkFactor
        }

        return normalizeRatios(result)
    }

    // MARK: - Window Placements

    static func calculateAllWindowPlacements(
        calculatedLayout: GridCalculatedLayout,
        layout: GridLayoutDef,
        assignments: [String: [UInt32]],
        cellModes: [String: GridStackMode]?,
        cellRatios: [String: [Double]]?,
        defaultMode: GridStackMode,
        baseSpacing: Double,
        settingsPadding: GridPadding?,
        settingsWindowSpacing: GridPaddingValue?
    ) -> [GridWindowPlacement] {
        var placements: [GridWindowPlacement] = []

        for (cellID, windowIDs) in assignments {
            guard var cellBounds = calculatedLayout.cellBounds[cellID] else {
                continue
            }

            // Apply padding inset (cell -> layout -> settings hierarchy)
            if let padding = getEffectivePadding(
                layout: layout,
                cellID: cellID,
                settingsPadding: settingsPadding
            ) {
                let resolved = padding.resolve(baseSpacing: baseSpacing)
                cellBounds = applyPaddingInset(bounds: cellBounds, padding: resolved)
            }

            // Determine stack mode (cellModes override -> defaultMode)
            var mode = defaultMode
            if let m = cellModes?[cellID], m != defaultMode {
                mode = m
            }

            // Get split ratios, adjust for actual window count
            var ratios: [Double]? = nil
            if let r = cellRatios?[cellID] {
                ratios = adjustRatiosForWindowCount(r, newCount: windowIDs.count)
            }

            // Determine window spacing (cell -> layout -> settings hierarchy)
            var windowSpacing: Double = 0
            if let ws = getEffectiveWindowSpacing(
                layout: layout,
                cellID: cellID,
                settingsSpacing: settingsWindowSpacing
            ) {
                windowSpacing = ws.resolve(baseSpacing: baseSpacing)
            }

            // Calculate window bounds within padded cell
            let windowBounds = calculateWindowBounds(
                cellBounds: cellBounds,
                windowCount: windowIDs.count,
                mode: mode,
                ratios: ratios,
                padding: windowSpacing
            )

            // Create placements pairing window IDs with bounds
            for (i, windowID) in windowIDs.enumerated() {
                if i < windowBounds.count {
                    placements.append(GridWindowPlacement(
                        windowID: windowID,
                        bounds: windowBounds[i]
                    ))
                }
            }
        }

        return placements
    }

    // MARK: - Effective Padding/Spacing Resolution

    static func getEffectivePadding(
        layout: GridLayoutDef,
        cellID: String,
        settingsPadding: GridPadding?
    ) -> GridPadding? {
        // Check cell-level override first
        for cell in layout.cells {
            if cell.id == cellID, let cellPadding = cell.padding {
                return cellPadding
            }
        }
        // Fall back to layout default
        if let layoutPadding = layout.padding {
            return layoutPadding
        }
        // Fall back to settings default
        return settingsPadding
    }

    static func getEffectiveWindowSpacing(
        layout: GridLayoutDef,
        cellID: String,
        settingsSpacing: GridPaddingValue?
    ) -> GridPaddingValue? {
        // Check cell-level override first
        for cell in layout.cells {
            if cell.id == cellID, let cellSpacing = cell.windowSpacing {
                return cellSpacing
            }
        }
        // Fall back to layout default
        if let layoutSpacing = layout.windowSpacing {
            return layoutSpacing
        }
        // Fall back to settings default
        return settingsSpacing
    }

    static func applyPaddingInset(
        bounds: CGRect,
        padding: GridResolvedPadding
    ) -> CGRect {
        CGRect(
            x: bounds.origin.x + padding.left,
            y: bounds.origin.y + padding.top,
            width: Swift.max(0, bounds.width - padding.left - padding.right),
            height: Swift.max(0, bounds.height - padding.top - padding.bottom)
        )
    }

    // MARK: - Split Ratio Adjustment

    static func adjustSplitRatio(
        ratios: [Double],
        index: Int,
        delta: Double,
        minRatio: Double
    ) -> Result<[Double], GridLayoutError> {
        if ratios.count < 2 {
            return .failure(.needAtLeastTwoWindows)
        }
        if index < 0 || index >= ratios.count - 1 {
            return .failure(.invalidSplitIndex(index))
        }

        var newRatios = ratios

        var newFirst = newRatios[index] + delta
        var newSecond = newRatios[index + 1] - delta

        // Enforce minimum ratios
        if newFirst < minRatio {
            newFirst = minRatio
            newSecond = newRatios[index + 1] + (newRatios[index] - minRatio)
        }
        if newSecond < minRatio {
            newSecond = minRatio
            newFirst = newRatios[index] + (newRatios[index + 1] - minRatio)
        }

        newRatios[index] = newFirst
        newRatios[index + 1] = newSecond

        return .success(normalizeRatios(newRatios))
    }

    static func adjustSplitRatioWithMax(
        ratios: [Double],
        index: Int,
        delta: Double,
        minRatio: Double,
        maxRatio: Double
    ) -> Result<[Double], GridLayoutError> {
        if ratios.count < 2 {
            return .failure(.needAtLeastTwoWindows)
        }
        if index < 0 || index >= ratios.count - 1 {
            return .failure(.invalidSplitIndex(index))
        }

        var newRatios = ratios

        var newFirst = newRatios[index] + delta
        var newSecond = newRatios[index + 1] - delta

        // Enforce minimum ratios
        if newFirst < minRatio {
            newFirst = minRatio
            newSecond = newRatios[index + 1] + (newRatios[index] - minRatio)
        }
        if newSecond < minRatio {
            newSecond = minRatio
            newFirst = newRatios[index] + (newRatios[index + 1] - minRatio)
        }

        // Enforce maximum ratios
        if newFirst > maxRatio {
            let excess = newFirst - maxRatio
            newFirst = maxRatio
            newSecond = newSecond + excess
        }
        if newSecond > maxRatio {
            let excess = newSecond - maxRatio
            newSecond = maxRatio
            newFirst = newFirst + excess
        }

        newRatios[index] = newFirst
        newRatios[index + 1] = newSecond

        return .success(normalizeRatios(newRatios))
    }

    static func adjustSplitRatioAtBoundary(
        ratios: [Double],
        boundaryIndex: Int,
        delta: Double
    ) -> Result<[Double], GridLayoutError> {
        adjustSplitRatio(
            ratios: ratios,
            index: boundaryIndex,
            delta: delta,
            minRatio: minimumRatio
        )
    }

    static func recalculateSplitsAfterRemoval(
        ratios: [Double],
        removedIndex: Int
    ) -> [Double] {
        if ratios.count <= 1 { return [1.0] }
        if removedIndex < 0 || removedIndex >= ratios.count { return ratios }

        let removed = ratios[removedIndex]
        var newRatios = [Double]()
        newRatios.reserveCapacity(ratios.count - 1)

        for (i, r) in ratios.enumerated() {
            if i != removedIndex {
                newRatios.append(r)
            }
        }

        // Distribute removed ratio equally to remaining
        let bonus = removed / Double(newRatios.count)
        for i in newRatios.indices {
            newRatios[i] += bonus
        }

        return normalizeRatios(newRatios)
    }

    static func recalculateSplitsAfterAddition(
        ratios: [Double],
        newIndex: Int
    ) -> [Double] {
        if ratios.isEmpty { return [1.0] }

        let newCount = ratios.count + 1
        let newRatio = 1.0 / Double(newCount)
        let scale = 1.0 - newRatio

        var newRatios = [Double](repeating: 0, count: newCount)
        for (i, r) in ratios.enumerated() {
            let destIndex = i >= newIndex ? i + 1 : i
            newRatios[destIndex] = r * scale
        }
        newRatios[newIndex] = newRatio

        return normalizeRatios(newRatios)
    }

    static func recalculateSplitsAfterReorder(
        ratios: [Double],
        oldIndex: Int,
        newIndex: Int
    ) -> [Double] {
        if oldIndex == newIndex
            || oldIndex < 0 || newIndex < 0
            || oldIndex >= ratios.count || newIndex >= ratios.count {
            return ratios
        }

        var newRatios = ratios
        let ratio = newRatios[oldIndex]

        if oldIndex < newIndex {
            // Shift left
            for i in oldIndex..<newIndex {
                newRatios[i] = newRatios[i + 1]
            }
        } else {
            // Shift right
            for i in stride(from: oldIndex, through: newIndex + 1, by: -1) {
                newRatios[i] = newRatios[i - 1]
            }
        }
        newRatios[newIndex] = ratio

        return newRatios
    }

    static func calculateSplitBoundary(
        cellSize: Double,
        ratios: [Double],
        boundaryIndex: Int,
        padding: Double
    ) -> Double {
        if boundaryIndex < 0 || boundaryIndex >= ratios.count {
            return 0
        }

        // Sum ratios up to and including boundaryIndex
        var totalRatio: Double = 0
        for i in 0...boundaryIndex {
            totalRatio += ratios[i]
        }

        // Calculate available space (excluding padding between windows)
        let paddingTotal = padding * Double(ratios.count - 1)
        let availableSpace = cellSize - paddingTotal

        // Position includes window sizes plus padding between them
        let position = availableSpace * totalRatio + padding * Double(boundaryIndex + 1)

        return position
    }
}
