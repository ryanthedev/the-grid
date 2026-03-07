import Foundation
import CoreGraphics

// MARK: - Constants

/// Minimum width/height for a window to be considered tileable.
/// Filters out toolbars (30px), tab bars, and other UI chrome.
private let minTileableDimension: Double = 100.0

// MARK: - Window Category

enum GridWindowCategory {
    case popup
    case floating
    case standard
}

// MARK: - Assignment Result

struct GridAssignmentResult: Sendable {
    /// Cell ID -> window IDs assigned to that cell
    var assignments: [String: [UInt32]]
    /// Windows that should float (not tiled)
    var floating: [UInt32]
    /// Windows excluded entirely (minimized, hidden, overlay)
    var excluded: [UInt32]
}

// MARK: - Terminal Apps Allowlist

/// Apps allowed to tile even without fullscreen button.
/// They often lack it but are definitely tileable.
private let terminalApps: Set<String> = [
    "Alacritty", "iTerm2", "Terminal", "kitty", "WezTerm",
    "Hyper", "Code", "Visual Studio Code", "Emacs",
    "GIMP", "Activity Monitor", "Steam",
]

// MARK: - Window Classification

/// Determine category from AX properties.
/// Combined port of Go's ClassifyWindow + ClassifyWindowWithPIPDetection.
func classifyWindow(window: WindowState, appName: String) -> GridWindowCategory {
    // Minimized or hidden => popup (excluded from everything)
    if window.isMinimized || window.isHidden {
        return .popup
    }

    // Non-zero level => floating (overlay windows)
    if window.level != 0 {
        return .floating
    }

    // No AX role data available => use button heuristics
    let role = window.role ?? ""
    if role.isEmpty {
        let noButtons = !window.hasCloseButton
            && !window.hasFullscreenButton
            && !window.hasMinimizeButton
            && !window.hasZoomButton
        if noButtons {
            return .popup
        }
        // Has some buttons but no role => treat as standard for safety
        return .standard
    }

    // Must be AXWindow role
    if role != "AXWindow" {
        return .popup
    }

    // Check subrole
    let subrole = window.subrole ?? ""
    switch subrole {
    case "AXUnknown", "":
        let noButtons = !window.hasCloseButton
            && !window.hasFullscreenButton
            && !window.hasMinimizeButton
            && !window.hasZoomButton
        if noButtons {
            return .popup
        }
        return .standard

    case "AXDialog", "AXFloatingWindow":
        return .floating

    case "AXStandardWindow":
        if window.isModal {
            return .floating
        }
        // PIP detection: no fullscreen button AND not a known terminal app
        if !window.hasFullscreenButton && !terminalApps.contains(appName) {
            return .floating
        }
        return .standard

    default:
        // Other subroles (AXSheet, etc.) => floating
        return .floating
    }
}

// MARK: - Tileable Filtering

/// Should this window be included in tiling at all?
func isTileable(window: WindowState) -> Bool {
    // Basic state checks
    if window.isMinimized || window.isHidden || window.level != 0 {
        return false
    }

    // Filter windows with invalid dimensions (toolbars, tab bars)
    if Double(window.frame.height) < minTileableDimension
        || Double(window.frame.width) < minTileableDimension {
        return false
    }

    // Only tile standard subroles
    let subrole = window.subrole ?? ""
    if !subrole.isEmpty && subrole != "AXStandardWindow" {
        return false
    }

    // Must have valid AX window role -- phantoms have empty/nil role
    return window.role == "AXWindow"
}

/// Check against configured exclusion list.
func isExcluded(
    window: WindowState,
    appName: String,
    exclusions: GridWindowExclusion
) -> Bool {
    if exclusions.roles.contains(window.role ?? "") {
        return true
    }
    if exclusions.subroles.contains(window.subrole ?? "") {
        return true
    }
    if exclusions.apps.contains(appName) {
        return true
    }
    return false
}

// MARK: - App Rule Matching

/// Check if window matches an app rule by appName or bundleID.
private func matchesAppRule(
    appName: String,
    bundleID: String?,
    rule: GridAppRule
) -> Bool {
    return rule.app == appName || rule.app == (bundleID ?? "")
}

/// Check if window should float based on rules + classification.
private func shouldFloat(
    window: WindowState,
    appName: String,
    bundleID: String?,
    appRules: [GridAppRule]
) -> Bool {
    // Check app rules first (explicit float = true)
    for rule in appRules {
        if matchesAppRule(appName: appName, bundleID: bundleID, rule: rule) && rule.float {
            return true
        }
    }

    // Fall back to window classification (includes PIP detection)
    let category = classifyWindow(window: window, appName: appName)
    return category == .floating
}

/// Check if window should be excluded entirely.
private func shouldExclude(window: WindowState) -> Bool {
    return window.isMinimized || window.isHidden || window.level != 0
}

/// Get preferred cell for a window from app rules.
private func getPreferredCell(
    appName: String,
    bundleID: String?,
    appRules: [GridAppRule]
) -> String? {
    for rule in appRules {
        if matchesAppRule(appName: appName, bundleID: bundleID, rule: rule),
           let cell = rule.preferredCell, !cell.isEmpty {
            return cell
        }
    }
    return nil
}

// MARK: - Main Assignment Entry Point

enum GridAssignment {

    /// Distribute windows to cells based on strategy.
    ///
    /// - Parameters:
    ///   - windows: All windows on the current space (unfiltered)
    ///   - layout: The layout definition being applied
    ///   - cellBounds: Pre-calculated cell bounds (from GridLayout.calculateLayout)
    ///   - appRules: App-specific rules from config
    ///   - previousAssignments: Previous cell->windowIDs mapping (for preserve strategy)
    ///   - strategy: Which assignment algorithm to use
    ///   - bundleIDLookup: Closure to resolve PID -> bundleID
    ///
    /// - Returns: GridAssignmentResult with cell assignments, floating, and excluded lists
    static func assignWindows(
        windows: [WindowState],
        layout: GridLayoutDef,
        cellBounds: [String: CGRect],
        appRules: [GridAppRule],
        previousAssignments: [String: [UInt32]],
        strategy: GridAssignmentStrategy,
        bundleIDLookup: (pid_t) -> String?
    ) -> GridAssignmentResult {
        var result = GridAssignmentResult(
            assignments: [:],
            floating: [],
            excluded: []
        )

        // Initialize empty assignments for all cells
        for cell in layout.cells {
            result.assignments[cell.id] = []
        }

        // Phase 1: Classify each window as tileable, floating, or excluded
        var tileable: [WindowState] = []

        for window in windows {
            let appName = window.appName ?? ""
            let bundleID = bundleIDLookup(window.pid)

            // Check excluded first (minimized, hidden, overlay)
            if shouldExclude(window: window) {
                result.excluded.append(window.id)
                continue
            }

            // Check if should float
            if shouldFloat(window: window, appName: appName, bundleID: bundleID, appRules: appRules) {
                result.floating.append(window.id)
                continue
            }

            tileable.append(window)
        }

        // Phase 2: Apply assignment strategy to tileable windows
        switch strategy {
        case .pinned:
            assignPinned(
                windows: tileable,
                layout: layout,
                appRules: appRules,
                bundleIDLookup: bundleIDLookup,
                result: &result
            )
        case .preserve:
            assignPreserve(
                windows: tileable,
                layout: layout,
                previousAssignments: previousAssignments,
                result: &result
            )
        case .autoFlow:
            assignAutoFlow(
                windows: tileable,
                layout: layout,
                cellBounds: cellBounds,
                result: &result
            )
        case .position:
            assignByPosition(
                windows: tileable,
                cellBounds: cellBounds,
                result: &result
            )
        }

        return result
    }

    // MARK: - Assignment Strategies

    /// Round-robin windows across cells sorted by visual position.
    private static func assignAutoFlow(
        windows: [WindowState],
        layout: GridLayoutDef,
        cellBounds: [String: CGRect],
        result: inout GridAssignmentResult
    ) {
        if windows.isEmpty || layout.cells.isEmpty {
            return
        }

        // Sort cells by visual position (top-to-bottom, left-to-right)
        var sortedCells = GridLayout.sortCellsByPosition(cellBounds: cellBounds)

        // Fallback: use cell order from layout definition
        if sortedCells.isEmpty {
            sortedCells = layout.cells.map { $0.id }
        }

        // Round-robin: window[i] goes to cell[i % cellCount]
        for (i, window) in windows.enumerated() {
            let cellID = sortedCells[i % sortedCells.count]
            result.assignments[cellID, default: []].append(window.id)
        }
    }

    /// Assign windows to preferred cells from app rules, then distribute remainder.
    private static func assignPinned(
        windows: [WindowState],
        layout: GridLayoutDef,
        appRules: [GridAppRule],
        bundleIDLookup: (pid_t) -> String?,
        result: inout GridAssignmentResult
    ) {
        var unpinned: [WindowState] = []

        // First pass: assign windows with preferred cells
        for window in windows {
            let appName = window.appName ?? ""
            let bundleID = bundleIDLookup(window.pid)
            let preferredCell = getPreferredCell(
                appName: appName,
                bundleID: bundleID,
                appRules: appRules
            )

            if let cell = preferredCell, result.assignments[cell] != nil {
                result.assignments[cell]!.append(window.id)
            } else {
                unpinned.append(window)
            }
        }

        // Second pass: distribute unpinned to empty cells first, then least-populated
        if !unpinned.isEmpty {
            let emptyCells = result.assignments.keys
                .filter { result.assignments[$0]?.isEmpty == true }
                .sorted()

            for (i, window) in unpinned.enumerated() {
                if i < emptyCells.count {
                    result.assignments[emptyCells[i]]!.append(window.id)
                } else {
                    let cellID = findLeastPopulatedCell(assignments: result.assignments)
                    result.assignments[cellID, default: []].append(window.id)
                }
            }
        }
    }

    /// Maintain previous assignments where possible, auto-flow new windows.
    private static func assignPreserve(
        windows: [WindowState],
        layout: GridLayoutDef,
        previousAssignments: [String: [UInt32]],
        result: inout GridAssignmentResult
    ) {
        var unassigned: [WindowState] = []

        // Build reverse lookup: windowID -> previous cellID
        var prevCellMap: [UInt32: String] = [:]
        for (cellID, windowIDs) in previousAssignments {
            for wid in windowIDs {
                prevCellMap[wid] = cellID
            }
        }

        // First pass: preserve previous assignments if cell still exists
        for window in windows {
            if let prevCellID = prevCellMap[window.id],
               result.assignments[prevCellID] != nil {
                result.assignments[prevCellID]!.append(window.id)
            } else {
                unassigned.append(window)
            }
        }

        // Second pass: auto-flow unassigned to least-populated cells
        for window in unassigned {
            let cellID = findLeastPopulatedCell(assignments: result.assignments)
            result.assignments[cellID, default: []].append(window.id)
        }

        // Third pass: reorder windows within each cell to match previous order
        for (cellID, prevWindowIDs) in previousAssignments {
            guard let currentWindows = result.assignments[cellID],
                  !currentWindows.isEmpty else {
                continue
            }

            // Build set of currently assigned windows
            var currentSet = Set(currentWindows)

            // Rebuild: previous-order windows first, then new windows
            var reordered: [UInt32] = []

            for wid in prevWindowIDs {
                if currentSet.contains(wid) {
                    reordered.append(wid)
                    currentSet.remove(wid)
                }
            }

            // Append remaining (new windows not in previous)
            for wid in currentWindows {
                if currentSet.contains(wid) {
                    reordered.append(wid)
                }
            }

            result.assignments[cellID] = reordered
        }
    }

    /// Assign each window to the cell with maximum frame overlap.
    private static func assignByPosition(
        windows: [WindowState],
        cellBounds: [String: CGRect],
        result: inout GridAssignmentResult
    ) {
        // Build zOrder lookup from input windows
        var zOrderLookup: [UInt32: Int32] = [:]
        for window in windows {
            zOrderLookup[window.id] = window.zOrder
        }

        for window in windows {
            var bestCell = ""
            var bestOverlap = 0.0

            for (cellID, bounds) in cellBounds {
                let overlap = window.frame.overlapArea(with: bounds)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestCell = cellID
                }
            }

            if !bestCell.isEmpty {
                result.assignments[bestCell, default: []].append(window.id)
            } else {
                // No overlap with any cell -- assign to least populated
                let cellID = findLeastPopulatedCell(assignments: result.assignments)
                result.assignments[cellID, default: []].append(window.id)
            }
        }

        // Sort windows within each cell by z-order (ascending = frontmost first)
        for cellID in result.assignments.keys {
            guard let windowIDs = result.assignments[cellID],
                  windowIDs.count > 1 else {
                continue
            }
            result.assignments[cellID] = windowIDs.sorted { a, b in
                let zA = zOrderLookup[a] ?? Int32.max
                let zB = zOrderLookup[b] ?? Int32.max
                return zA < zB
            }
        }
    }

    // MARK: - Helpers

    /// Return cellID with fewest assigned windows.
    /// Alphabetical tiebreaker for determinism.
    private static func findLeastPopulatedCell(
        assignments: [String: [UInt32]]
    ) -> String {
        return assignments.keys.sorted().min { a, b in
            (assignments[a]?.count ?? 0) < (assignments[b]?.count ?? 0)
        } ?? ""
    }
}
