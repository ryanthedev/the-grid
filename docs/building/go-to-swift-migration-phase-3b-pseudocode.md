# Pseudocode: Phase 3b - Window Assignment + Classification

## Files to Create/Modify
- **Create:** `grid-server/Sources/GridServer/Grid/GridAssignment.swift`
- **Modify:** `grid-server/Sources/GridServer/Grid/GridLayout.swift` (add `CGRect.overlapArea` extension)

## Design Decision: Window Type

GridAssignment works directly with `WindowState` (from StateModels.swift). No adapter or protocol needed -- this is a server-internal module and WindowState already has every field the assignment logic requires. BundleID is resolved by passing a `bundleIDLookup: (pid_t) -> String?` closure from the caller (who has access to `StateManager.state.applications`).

## Pseudocode

### GridLayout.swift (modification -- add CGRect extension)

```
extension CGRect:
    func overlapArea(with other: CGRect) -> Double:
        // Calculate intersection rectangle
        left = max(self.minX, other.minX)
        right = min(self.maxX, other.maxX)
        top = max(self.minY, other.minY)
        bottom = min(self.maxY, other.maxY)

        if left >= right or top >= bottom:
            return 0

        return (right - left) * (bottom - top)
```

### GridAssignment.swift

```
// MARK: - Constants

MinTileableDimension = 100.0
// Minimum width/height for a window to be considered tileable.
// Filters out toolbars (30px), tab bars, and other UI chrome.

// MARK: - Window Category

enum GridWindowCategory:
    case popup    // Ignore completely (menus, tooltips, no-role windows)
    case floating // Track but don't tile (dialogs, PIP, modals)
    case standard // Normal tileable window

// MARK: - Assignment Result

struct GridAssignmentResult:
    var assignments: [String: [UInt32]]  // cellID -> window IDs
    var floating: [UInt32]               // Windows that should float
    var excluded: [UInt32]               // Windows excluded entirely

// MARK: - Terminal Apps Allowlist

// Apps allowed to tile even without fullscreen button
// (they often lack it but are definitely tileable)
terminalApps: Set<String> = [
    "Alacritty", "iTerm2", "Terminal", "kitty", "WezTerm",
    "Hyper", "Code", "Visual Studio Code", "Emacs",
    "GIMP", "Activity Monitor", "Steam"
]

// MARK: - Window Classification

// classifyWindow: Determine category from AX properties
// Port of Go's ClassifyWindow + ClassifyWindowWithPIPDetection combined
func classifyWindow(window: WindowState, appName: String) -> GridWindowCategory:

    // 1. Minimized or hidden => popup (excluded from everything)
    if window.isMinimized or window.isHidden:
        return .popup

    // 2. Non-zero level => floating (overlay windows)
    if window.level != 0:
        return .floating

    // 3. No AX role data available => use button heuristics
    role = window.role ?? ""
    if role is empty:
        if no buttons at all (close, fullscreen, minimize, zoom all false):
            return .popup
        // Has some buttons but no role => treat as standard for safety
        return .standard

    // 4. Must be AXWindow role
    if role != "AXWindow":
        return .popup

    // 5. Check subrole
    subrole = window.subrole ?? ""
    switch subrole:
        case "AXUnknown", "":
            if no buttons at all:
                return .popup
            return .standard

        case "AXDialog", "AXFloatingWindow":
            return .floating

        case "AXStandardWindow":
            if window.isModal:
                return .floating
            // PIP detection: no fullscreen button AND not a known terminal app
            if not window.hasFullscreenButton and appName not in terminalApps:
                return .floating
            return .standard

        default:
            // Other subroles (AXSheet, etc.) => floating
            return .floating


// MARK: - Tileable Filtering

// isTileable: Should this window be included in tiling at all?
// Port of Go's WindowInfo.IsTileable()
func isTileable(window: WindowState) -> Bool:
    // Basic state checks
    if window.isMinimized or window.isHidden or window.level != 0:
        return false

    // Filter windows with invalid dimensions (toolbars, tab bars)
    if window.frame.height < MinTileableDimension or window.frame.width < MinTileableDimension:
        return false

    // Only tile standard subroles
    subrole = window.subrole ?? ""
    if subrole is not empty and subrole != "AXStandardWindow":
        return false

    // Must have valid AX window role -- phantoms have empty/nil role
    return window.role == "AXWindow"


// isExcluded: Check against configured exclusion list
func isExcluded(window: WindowState, appName: String, exclusions: GridWindowExclusion) -> Bool:
    if (window.role ?? "") in exclusions.roles:
        return true
    if (window.subrole ?? "") in exclusions.subroles:
        return true
    if appName in exclusions.apps:
        return true
    return false


// MARK: - App Rule Matching

// matchesAppRule: Check if window matches an app rule by appName or bundleID
func matchesAppRule(
    appName: String,
    bundleID: String?,
    rule: GridAppRule
) -> Bool:
    return rule.app == appName or rule.app == (bundleID ?? "")


// shouldFloat: Check if window should float based on rules + classification
func shouldFloat(
    window: WindowState,
    appName: String,
    bundleID: String?,
    appRules: [GridAppRule]
) -> Bool:
    // Check app rules first (explicit float = true)
    for rule in appRules:
        if matchesAppRule(appName, bundleID, rule) and rule.float:
            return true

    // Fall back to window classification (includes PIP detection)
    category = classifyWindow(window, appName)
    return category == .floating


// shouldExclude: Check if window should be excluded entirely
func shouldExclude(window: WindowState) -> Bool:
    return window.isMinimized or window.isHidden or window.level != 0


// getPreferredCell: Get preferred cell for a window from app rules
func getPreferredCell(
    appName: String,
    bundleID: String?,
    appRules: [GridAppRule]
) -> String?:
    for rule in appRules:
        if matchesAppRule(appName, bundleID, rule) and rule.preferredCell is not nil/empty:
            return rule.preferredCell
    return nil


// MARK: - Main Assignment Entry Point

enum GridAssignment:

    // assignWindows: Distribute windows to cells based on strategy
    //
    // Parameters:
    //   windows: All windows on the current space (unfiltered)
    //   layout: The layout definition being applied
    //   cellBounds: Pre-calculated cell bounds (from GridLayout.calculateLayout)
    //   appRules: App-specific rules from config
    //   previousAssignments: Previous cell->windowIDs mapping (for preserve strategy)
    //   strategy: Which assignment algorithm to use
    //   bundleIDLookup: Closure to resolve PID -> bundleID
    //
    // Returns: GridAssignmentResult with cell assignments, floating, and excluded lists
    static func assignWindows(
        windows: [WindowState],
        layout: GridLayoutDef,
        cellBounds: [String: CGRect],
        appRules: [GridAppRule],
        previousAssignments: [String: [UInt32]],
        strategy: GridAssignmentStrategy,
        bundleIDLookup: (pid_t) -> String?
    ) -> GridAssignmentResult:

        result = GridAssignmentResult(
            assignments: empty map initialized with empty arrays for each cell in layout,
            floating: [],
            excluded: []
        )

        // Initialize empty assignments for all cells
        for cell in layout.cells:
            result.assignments[cell.id] = []

        // Phase 1: Classify each window as tileable, floating, or excluded
        var tileable: [WindowState] = []

        for window in windows:
            appName = window.appName ?? ""
            bundleID = bundleIDLookup(window.pid)

            // Check excluded first (minimized, hidden, overlay)
            if shouldExclude(window):
                result.excluded.append(window.id)
                continue

            // Check if should float
            if shouldFloat(window, appName, bundleID, appRules):
                result.floating.append(window.id)
                continue

            tileable.append(window)

        // Phase 2: Apply assignment strategy to tileable windows
        switch strategy:
            case .pinned:
                assignPinned(tileable, layout, appRules, bundleIDLookup, &result)
            case .preserve:
                assignPreserve(tileable, layout, previousAssignments, &result)
            case .autoFlow:
                assignAutoFlow(tileable, layout, cellBounds, &result)
            case .position:
                assignByPosition(tileable, cellBounds, &result)

        return result


    // MARK: - Assignment Strategies

    // assignAutoFlow: Round-robin windows across cells sorted by visual position
    private static func assignAutoFlow(
        windows, layout, cellBounds, result
    ):
        if windows is empty or layout.cells is empty:
            return

        // Sort cells by visual position (top-to-bottom, left-to-right)
        sortedCells = GridLayout.sortCellsByPosition(cellBounds: cellBounds)

        // Fallback: use cell order from layout definition
        if sortedCells is empty:
            sortedCells = layout.cells.map { $0.id }

        // Round-robin: window[i] goes to cell[i % cellCount]
        for (i, window) in windows.enumerated():
            cellID = sortedCells[i % sortedCells.count]
            result.assignments[cellID].append(window.id)


    // assignPinned: Assign windows to preferred cells from app rules, then distribute remainder
    private static func assignPinned(
        windows, layout, appRules, bundleIDLookup, result
    ):
        var unpinned: [WindowState] = []

        // First pass: assign windows with preferred cells
        for window in windows:
            appName = window.appName ?? ""
            bundleID = bundleIDLookup(window.pid)
            preferredCell = getPreferredCell(appName, bundleID, appRules)

            if preferredCell is not nil and result.assignments contains key preferredCell:
                result.assignments[preferredCell].append(window.id)
            else:
                unpinned.append(window)

        // Second pass: distribute unpinned to empty cells first, then least-populated
        if unpinned is not empty:
            emptyCells = result.assignments.keys
                .filter { result.assignments[$0].isEmpty }
                .sorted()  // alphabetical for determinism

            for (i, window) in unpinned.enumerated():
                if i < emptyCells.count:
                    cellID = emptyCells[i]
                else:
                    cellID = findLeastPopulatedCell(result.assignments)

                result.assignments[cellID].append(window.id)


    // assignPreserve: Maintain previous assignments where possible, auto-flow new windows
    private static func assignPreserve(
        windows, layout, previousAssignments, result
    ):
        var unassigned: [WindowState] = []

        // Build reverse lookup: windowID -> previous cellID
        prevCellMap: [UInt32: String] = [:]
        for (cellID, windowIDs) in previousAssignments:
            for wid in windowIDs:
                prevCellMap[wid] = cellID

        // First pass: preserve previous assignments if cell still exists
        for window in windows:
            if let prevCellID = prevCellMap[window.id],
               result.assignments contains key prevCellID:
                result.assignments[prevCellID].append(window.id)
            else:
                unassigned.append(window)

        // Second pass: auto-flow unassigned to least-populated cells
        for window in unassigned:
            cellID = findLeastPopulatedCell(result.assignments)
            result.assignments[cellID].append(window.id)

        // Third pass: reorder windows within each cell to match previous order
        for (cellID, prevWindowIDs) in previousAssignments:
            currentWindows = result.assignments[cellID]
            if currentWindows is nil or empty:
                continue

            // Build set of currently assigned windows
            currentSet = Set(currentWindows)

            // Rebuild: previous-order windows first, then new windows
            reordered: [UInt32] = []

            for wid in prevWindowIDs:
                if currentSet.contains(wid):
                    reordered.append(wid)
                    currentSet.remove(wid)

            // Append remaining (new windows not in previous)
            for wid in currentWindows:
                if currentSet.contains(wid):
                    reordered.append(wid)

            result.assignments[cellID] = reordered


    // assignByPosition: Assign each window to the cell with maximum frame overlap
    private static func assignByPosition(
        windows, cellBounds, result
    ):
        for window in windows:
            bestCell = ""
            bestOverlap = 0.0

            for (cellID, bounds) in cellBounds:
                overlap = window.frame.overlapArea(with: bounds)
                if overlap > bestOverlap:
                    bestOverlap = overlap
                    bestCell = cellID

            if bestCell is not empty:
                result.assignments[bestCell].append(window.id)
            else:
                // No overlap with any cell -- assign to least populated
                cellID = findLeastPopulatedCell(result.assignments)
                result.assignments[cellID].append(window.id)

        // Sort windows within each cell by z-order (frontmost first)
        for cellID in result.assignments.keys:
            windowIDs = result.assignments[cellID]
            if windowIDs.count > 1:
                // Build zOrder lookup from input windows
                sort windowIDs by their zOrder (ascending = frontmost first)
                result.assignments[cellID] = sorted windowIDs


    // MARK: - Helpers

    // findLeastPopulatedCell: Return cellID with fewest assigned windows
    // Alphabetical tiebreaker for determinism
    private static func findLeastPopulatedCell(
        assignments: [String: [UInt32]]
    ) -> String:
        sort keys alphabetically
        return key with minimum array count

```

## Design Notes

1. **No new abstraction layer.** GridAssignment works directly with `WindowState`. The server already tracks all the AX properties we need. Adding a protocol or adapter would be complexity without benefit since there's only one implementation.

2. **BundleID via closure.** Rather than requiring WindowState to carry bundleID (it doesn't -- it has PID), callers pass a `bundleIDLookup: (pid_t) -> String?` closure. This keeps assignment decoupled from StateManager's application tracking.

3. **Combined PIP detection.** Go has two separate functions (`ClassifyWindow` and `ClassifyWindowWithPIPDetection`). In Swift, we combine them into one `classifyWindow` since PIP detection is always wanted.

4. **`GridAssignment` as enum namespace.** Following the existing pattern of `GridLayout` (enum with static functions), GridAssignment is a caseless enum used as a namespace for pure functions.

5. **`terminalApps` as module-level Set.** Using a Set for O(1) lookup instead of Go's map.

6. **Logging.** Go logs every cell assignment with `jsonlog.Log`. In Swift, we use `jlog()` for consistency with the rest of the server. However, assignment is called frequently during layout apply, so logging individual assignments may be noisy. Log at the strategy level instead (which strategy was used, how many tileable/floating/excluded).

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (direct WindowState usage, closure for bundleID, combined classification)
- [x] Ready for implementation
