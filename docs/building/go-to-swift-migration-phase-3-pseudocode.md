# Pseudocode: Phase 3 - Layout Computation

## Files to Create/Modify
- **Create:** `grid-server/Sources/GridServer/Grid/GridLayout.swift`

## Pseudocode

### GridLayout.swift

```
// MARK: - Result Types

struct GridCalculatedLayout
    layoutID: String
    screenRect: CGRect
    gap: Double
    columnSizes: [Double]
    rowSizes: [Double]
    cellBounds: [String: CGRect]    // cellID -> calculated bounds

struct GridWindowPlacement
    windowID: UInt32
    bounds: CGRect

// MARK: - CGRect Extensions (for layout math)

extension CGRect
    var center: CGPoint
        return CGPoint(x: midX, y: midY)

    func overlapsVertically(with other: CGRect) -> Bool
        // Self's Y range intersects other's Y range
        return minY < other.maxY && maxY > other.minY

    func overlapsHorizontally(with other: CGRect) -> Bool
        // Self's X range intersects other's X range
        return minX < other.maxX && maxX > other.minX

// MARK: - Track Calculation

// Convert track definitions to pixel sizes
// Delegates to WithRatios with nil ratios
func calculateTracks(tracks: [GridTrackSize], available: Double, gap: Double) -> [Double]
    return calculateTracksWithRatios(tracks, available, gap, ratios: nil)

// Convert track definitions to pixel sizes with optional ratio overrides
func calculateTracksWithRatios(
    tracks: [GridTrackSize],
    available: Double,
    gap: Double,
    ratios: [Double]?
) -> [Double]
    If tracks is empty, return empty array

    Subtract total gaps from available space
        totalGaps = gap * (tracks.count - 1)
        available -= totalGaps

    Create sizes array of tracks.count, all zeros
    Set remaining = available

    // First pass: allocate fixed tracks, collect flexible track indices
    For each track with index:
        If track is .px:
            sizes[i] = track.value
            remaining -= track.value
        If track is .fr:
            Add track.value to totalFr
            Record index as frIndex
        If track is .minmax:
            sizes[i] = track.min
            remaining -= track.min
            Add track.max to totalFr (max is in fr units)
            Record index as frIndex
        If track is .auto:
            sizes[i] = 0

    // Second pass: distribute remaining space to flexible tracks
    If totalFr > 0 and remaining > 0:
        Check if ratios has same count as frIndices and is non-empty
        If using ratio overrides:
            For each fr index j:
                If track is .fr: sizes[i] = remaining * ratios[j]
                If track is .minmax: sizes[i] = track.min + remaining * ratios[j]
        Else (use original fr values):
            frUnit = remaining / totalFr
            For each fr index:
                If track is .fr: sizes[i] = frUnit * track.value
                If track is .minmax: sizes[i] = track.min + frUnit * track.max

    // Third pass: apply minmax constraints, ensure non-negative
    For each track:
        If track is .minmax and sizes[i] < track.min:
            sizes[i] = track.min
        If sizes[i] < 0:
            sizes[i] = 0

    Return sizes

// MARK: - Track Positions

// Return starting position of each track
// Result has length sizes.count + 1 (last entry = end of last track)
func calculateTrackPositions(sizes: [Double], gap: Double) -> [Double]
    Create positions array of sizes.count + 1
    positions[0] = 0

    For each size with index i:
        positions[i+1] = positions[i] + size
        If not the last track:
            positions[i+1] += gap

    Return positions

// MARK: - Cell Bounds

// Compute pixel rect for a single cell
// Cell spans are 1-indexed, exclusive end (CSS grid convention)
func calculateCellBounds(
    cell: GridCellDef,
    colPositions: [Double],
    rowPositions: [Double],
    colSizes: [Double],
    rowSizes: [Double],
    gap: Double
) -> CGRect
    // Convert 1-indexed to 0-indexed
    colStart = cell.columnStart - 1
    colEnd = cell.columnEnd - 1
    rowStart = cell.rowStart - 1
    rowEnd = cell.rowEnd - 1

    // Bounds checking - return .zero if invalid
    If colStart < 0 or colEnd > colSizes.count or colStart >= colEnd: return .zero
    If rowStart < 0 or rowEnd > rowSizes.count or rowStart >= rowEnd: return .zero

    // X position from column start, width spans columns + inter-column gaps
    x = colPositions[colStart]
    width = sum of colSizes[colStart..<colEnd] + gap for each interior column boundary

    // Y position from row start, height spans rows + inter-row gaps
    y = rowPositions[rowStart]
    height = sum of rowSizes[rowStart..<rowEnd] + gap for each interior row boundary

    Return CGRect(x, y, width, height)

// MARK: - Full Layout Calculation

// Main entry point: compute all cell bounds for a layout
func calculateLayout(
    layout: GridLayoutDef,
    screenRect: CGRect,
    gap: Double
) -> GridCalculatedLayout
    return calculateLayoutWithRatios(layout, screenRect, gap, columnRatios: nil, rowRatios: nil)

// Compute layout with optional column/row ratio overrides
func calculateLayoutWithRatios(
    layout: GridLayoutDef,
    screenRect: CGRect,
    gap: Double,
    columnRatios: [Double]?,
    rowRatios: [Double]?
) -> GridCalculatedLayout
    // Calculate track sizes
    columnSizes = calculateTracksWithRatios(layout.columns, screenRect.width, gap, columnRatios)
    rowSizes = calculateTracksWithRatios(layout.rows, screenRect.height, gap, rowRatios)

    // Calculate track positions
    colPositions = calculateTrackPositions(columnSizes, gap)
    rowPositions = calculateTrackPositions(rowSizes, gap)

    // Calculate bounds for each cell
    cellBounds: [String: CGRect] = [:]
    For each cell in layout.cells:
        bounds = calculateCellBounds(cell, colPositions, rowPositions, colSizes, rowSizes, gap)
        // Offset by screen position (display offset)
        bounds.origin.x += screenRect.origin.x
        bounds.origin.y += screenRect.origin.y
        cellBounds[cell.id] = bounds

    Return GridCalculatedLayout(
        layoutID: layout.id,
        screenRect: screenRect,
        gap: gap,
        columnSizes: columnSizes,
        rowSizes: rowSizes,
        cellBounds: cellBounds
    )

// MARK: - Cell Queries

// Find which cell contains a given point
func getCellAtPoint(cellBounds: [String: CGRect], point: CGPoint) -> String?
    For each (cellID, bounds) in cellBounds:
        If bounds contains point:
            Return cellID
    Return nil

// Return cells adjacent to a given cell in each direction
// Adjacency = center offset in primary axis + perpendicular overlap
// Results sorted by cell ID for deterministic ordering
func getAdjacentCells(
    cellID: String,
    cellBounds: [String: CGRect]
) -> [GridDirection: [String]]
    Initialize result with empty arrays for all four directions

    Get current cell bounds, return empty result if not found
    Get currentCenter = current.center

    For each other (id, bounds) in cellBounds:
        Skip if id == cellID
        Get otherCenter = bounds.center
        dx = otherCenter.x - currentCenter.x
        dy = otherCenter.y - currentCenter.y

        If dx < 0 and current overlaps vertically with bounds:
            Append id to result[.left]
        If dx > 0 and current overlaps vertically with bounds:
            Append id to result[.right]
        If dy < 0 and current overlaps horizontally with bounds:
            Append id to result[.up]
        If dy > 0 and current overlaps horizontally with bounds:
            Append id to result[.down]

    Sort each direction's array alphabetically
    Return result

// Return cell IDs sorted by visual position (top-to-bottom, left-to-right)
func sortCellsByPosition(cellBounds: [String: CGRect]) -> [String]
    Get all cell IDs
    Sort by: Y first (top-to-bottom), then X (left-to-right)
    Return sorted IDs

// MARK: - Window Stacking

// Compute bounds for windows stacked within a cell
func calculateWindowBounds(
    cellBounds: CGRect,
    windowCount: Int,
    mode: GridStackMode,
    ratios: [Double]?,
    padding: Double
) -> [CGRect]
    If windowCount == 0: return empty

    // Use equal ratios if not provided or wrong length
    Resolve ratios: if nil or wrong count, use equalRatios(windowCount)

    Switch on mode:
        .vertical: return calculateVerticalStack(cellBounds, ratios, padding)
        .horizontal: return calculateHorizontalStack(cellBounds, ratios, padding)
        .tabs: return array of windowCount copies of cellBounds

// Arrange windows top-to-bottom within cell
func calculateVerticalStack(cellBounds: CGRect, ratios: [Double], padding: Double) -> [CGRect]
    totalPadding = padding * (ratios.count - 1)
    availableHeight = cellBounds.height - totalPadding
    y = cellBounds.origin.y

    For each ratio:
        height = availableHeight * ratio
        Create rect at (cellBounds.x, y, cellBounds.width, height)
        y += height + padding

    Return rects

// Arrange windows left-to-right within cell
func calculateHorizontalStack(cellBounds: CGRect, ratios: [Double], padding: Double) -> [CGRect]
    totalPadding = padding * (ratios.count - 1)
    availableWidth = cellBounds.width - totalPadding
    x = cellBounds.origin.x

    For each ratio:
        width = availableWidth * ratio
        Create rect at (x, cellBounds.y, width, cellBounds.height)
        x += width + padding

    Return rects

// MARK: - Ratio Utilities (shared, replaces duplicate code in GridState)

// Return array of N equal ratios summing to 1.0
func equalRatios(_ n: Int) -> [Double]
    If n <= 0: return empty
    Return array of n copies of (1.0 / n)

// Normalize ratios to sum to 1.0
// If all zeros, return equal ratios
func normalizeRatios(_ ratios: [Double]) -> [Double]
    If empty: return empty
    sum = ratios.reduce(0, +)
    If sum == 0: return equalRatios(ratios.count)
    Return ratios.map { $0 / sum }

// Adjust ratios when window count changes
// Shrinking: drop last N ratios, renormalize
// Growing: take equal space from existing for new windows
// Same: just normalize
func adjustRatiosForWindowCount(_ ratios: [Double], newCount: Int) -> [Double]
    If newCount <= 0: return empty
    If ratios empty: return equalRatios(newCount)

    If same count: return normalizeRatios(ratios)

    If shrinking:
        Truncate to newCount, normalize

    If growing:
        newRatio = 1.0 / newCount
        shrinkFactor = oldCount / newCount
        Scale existing ratios by shrinkFactor
        New entries get newRatio
        Normalize result

// MARK: - Window Placements (orchestrates padding + spacing + stacking)

// Compute placements for all windows across all cells in a layout
func calculateAllWindowPlacements(
    calculatedLayout: GridCalculatedLayout,
    layout: GridLayoutDef,
    assignments: [String: [UInt32]],
    cellModes: [String: GridStackMode]?,
    cellRatios: [String: [Double]]?,
    defaultMode: GridStackMode,
    baseSpacing: Double,
    settingsPadding: GridPadding?,
    settingsWindowSpacing: GridPaddingValue?
) -> [GridWindowPlacement]
    For each (cellID, windowIDs) in assignments:
        Get cellBounds from calculatedLayout, skip if missing

        // Apply padding inset (cell -> layout -> settings hierarchy)
        Get effective padding for this cell
        If padding exists, resolve and inset cellBounds

        // Determine stack mode (cellModes override -> defaultMode)
        mode = cellModes?[cellID] ?? defaultMode

        // Get split ratios, adjust for actual window count
        ratios = cellRatios?[cellID]
        If ratios exist, adjust for windowIDs.count

        // Determine window spacing (cell -> layout -> settings hierarchy)
        windowSpacing = getEffectiveWindowSpacing(layout, cellID, settingsSpacing)
        Resolve to pixels

        // Calculate window bounds within padded cell
        windowBounds = calculateWindowBounds(cellBounds, windowIDs.count, mode, ratios, windowSpacing)

        // Create placements pairing window IDs with bounds
        For each (windowID, bounds) pair:
            Append GridWindowPlacement(windowID, bounds)

    Return all placements

// MARK: - Effective Padding/Spacing Resolution

// Priority: cell override > layout default > settings default
func getEffectivePadding(
    layout: GridLayoutDef,
    cellID: String,
    settingsPadding: GridPadding?
) -> GridPadding?
    Check cell-level override first (search layout.cells for matching ID)
    Fall back to layout.padding
    Fall back to settingsPadding

// Priority: cell override > layout default > settings default
func getEffectiveWindowSpacing(
    layout: GridLayoutDef,
    cellID: String,
    settingsSpacing: GridPaddingValue?
) -> GridPaddingValue?
    Check cell-level windowSpacing override first
    Fall back to layout.windowSpacing
    Fall back to settingsSpacing

// Apply padding inset to shrink a rect
func applyPaddingInset(bounds: CGRect, padding: GridResolvedPadding) -> CGRect
    Return CGRect(
        x: bounds.x + padding.left,
        y: bounds.y + padding.top,
        width: max(0, bounds.width - padding.left - padding.right),
        height: max(0, bounds.height - padding.top - padding.bottom)
    )

// MARK: - Split Ratio Adjustment

let minimumRatio = 0.1
let defaultResizeAmount = 0.1

// Adjust ratio between two adjacent windows
// index = window to grow, index+1 = window to shrink
// Enforces minimum ratio constraint
func adjustSplitRatio(
    ratios: [Double],
    index: Int,
    delta: Double,
    minRatio: Double
) -> Result<[Double], GridLayoutError>
    If ratios.count < 2: return error "need at least 2 windows"
    If index out of bounds: return error

    Copy ratios
    newFirst = ratios[index] + delta
    newSecond = ratios[index+1] - delta

    // Clamp to minimum
    If newFirst < minRatio: redistribute from second
    If newSecond < minRatio: redistribute from first

    Set new values, normalize, return

// Same as above but with max ratio constraint too
func adjustSplitRatioWithMax(
    ratios: [Double],
    index: Int,
    delta: Double,
    minRatio: Double,
    maxRatio: Double
) -> Result<[Double], GridLayoutError>
    Same as adjustSplitRatio but also clamp to maxRatio

// Convenience: adjust at boundary index with default minimum
func adjustSplitRatioAtBoundary(
    ratios: [Double],
    boundaryIndex: Int,
    delta: Double
) -> Result<[Double], GridLayoutError>
    return adjustSplitRatio(ratios, boundaryIndex, delta, minimumRatio)

// Recalculate ratios after removing a window
// Removed window's ratio is distributed equally to remaining
func recalculateSplitsAfterRemoval(ratios: [Double], removedIndex: Int) -> [Double]
    If ratios.count <= 1: return [1.0]
    If removedIndex out of bounds: return ratios

    Save removed ratio
    Remove from array
    Distribute removed ratio equally to remaining
    Normalize and return

// Recalculate ratios after adding a window at a specific index
// New window gets equal share, existing are scaled down proportionally
func recalculateSplitsAfterAddition(ratios: [Double], newIndex: Int) -> [Double]
    If ratios empty: return [1.0]

    newCount = ratios.count + 1
    newRatio = 1.0 / newCount
    scale = 1.0 - newRatio

    Create new array, inserting newRatio at newIndex
    Scale existing entries by scale factor
    Normalize and return

// Reorder ratios when windows are reordered (move ratio with its window)
func recalculateSplitsAfterReorder(ratios: [Double], oldIndex: Int, newIndex: Int) -> [Double]
    If same index or out of bounds: return ratios
    Copy, shift elements, place moved ratio at new position

// Calculate the pixel position of a split boundary
func calculateSplitBoundary(
    cellSize: Double,
    ratios: [Double],
    boundaryIndex: Int,
    padding: Double
) -> Double
    Sum ratios up to and including boundaryIndex
    Calculate available space (cellSize - total padding)
    Position = availableSpace * totalRatio + padding * (boundaryIndex + 1)
    Return position

// MARK: - Error Type

enum GridLayoutError: Error
    case needAtLeastTwoWindows
    case invalidSplitIndex(Int)
```

## Design Notes

### Design: GridLayout Module

#### Approaches Considered
1. **Enum namespace** - All functions as static methods on `enum GridLayout` (namespace pattern, no instances)
2. **Free functions** - Module-level functions, no namespace wrapper
3. **Struct with stored state** - Layout calculator that holds config references

#### Comparison
| Criterion | Enum Namespace | Free Functions | Stateful Struct |
|-----------|---------------|----------------|-----------------|
| Interface simplicity | Good - clear grouping | Best - no wrapper | Medium - needs init |
| Information hiding | N/A (pure functions) | N/A (pure functions) | Hides config access |
| Caller ease of use | `GridLayout.calculateTracks(...)` | `calculateTracks(...)` | `calculator.calculateTracks(...)` |
| Consistency with Go | Close (package functions) | Closest match | Different pattern |
| Swift idiom | Common for namespacing | Works but can clash | Overengineered for pure math |

#### Choice: Enum Namespace (A)
Rationale: Groups related layout functions under a clear namespace without requiring instantiation. Pure functions with no state match the Go source structure. The `GridLayout.` prefix prevents name collisions with potential future modules. Sacrificing brevity of free functions for better organization.

#### Depth Check
- Interface methods: ~15 public functions + 2 result types + 1 error type
- Hidden details: Track calculation algorithm (3-pass), minmax constraint handling, ratio adjustment math, padding resolution hierarchy
- Common case complexity: Simple - caller provides layout def + screen rect + gap, gets back cell bounds and window placements

### Key Decisions

1. **CGRect over custom Rect:** Use CoreGraphics `CGRect`/`CGPoint` throughout. The Go `types.Rect` maps directly. Small extensions for `center`, `overlapsVertically`, `overlapsHorizontally` cover the missing methods.

2. **Result types in GridLayout.swift:** `GridCalculatedLayout` and `GridWindowPlacement` are defined here, not in GridTypes.swift, because they are outputs of layout computation and not configuration types.

3. **Ratio utilities are public:** `equalRatios()`, `normalizeRatios()`, `adjustRatiosForWindowCount()` are public and canonical. GridState's private duplicates should eventually delegate to these (refactor can happen in Phase 3 implementation or later).

4. **Error handling via Result:** Split adjustment functions return `Result<[Double], GridLayoutError>` instead of Go's `([]float64, error)` tuple. This is more idiomatic Swift.

5. **Sendable:** All result types (`GridCalculatedLayout`, `GridWindowPlacement`) are `Sendable` since they are pure value types used across actor boundaries.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (enum namespace chosen over free functions and stateful struct)
- [x] Ready for implementation
