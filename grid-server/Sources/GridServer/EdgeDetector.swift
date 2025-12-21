//
// EdgeDetector.swift
// GridServer
//
// Detects when mouse cursor is near cell or window boundaries.
// Used by MouseHandler to determine resize target.
//

import Foundation
import CoreGraphics

/// Result of edge detection
struct EdgeHit {
    let resizeType: ResizeType
    let targetID: String
    let edge: ResizeEdge
    let distance: CGFloat  // Distance from the edge in pixels
}

/// Detects proximity to cell/window boundaries
struct EdgeDetector {
    /// Detection threshold in pixels
    let threshold: CGFloat

    init(threshold: CGFloat = 10.0) {
        self.threshold = threshold
    }

    /// Detect if point is near any resizable edge
    /// Priority: cell boundaries first (outer edges), then window splits (inner edges)
    func detectEdge(point: CGPoint, state: WindowManagerState) -> EdgeHit? {
        // First, try to detect cell boundary hits
        // Cell boundaries are the edges between grid cells
        if let cellHit = detectCellBoundary(point: point, state: state) {
            return cellHit
        }

        // Then, try to detect window split hits within a cell
        if let windowHit = detectWindowBoundary(point: point, state: state) {
            return windowHit
        }

        return nil
    }

    // MARK: - Cell Boundary Detection

    /// Detect if point is near a cell boundary
    /// This requires getting the cell layout from the CLI state (through RPC or cached)
    private func detectCellBoundary(point: CGPoint, state: WindowManagerState) -> EdgeHit? {
        // Get the active space
        guard let activeSpaceID = state.metadata.activeSpaceID else {
            Task { await JSONLogger.shared.log("dbg.edge.no_active_space", data: [:]) }
            return nil
        }

        // Get windows on this space to build cell boundaries
        let spaceKey = String(activeSpaceID)
        guard let space = state.spaces[spaceKey] else {
            Task { await JSONLogger.shared.log("dbg.edge.space_not_found", data: ["space": spaceKey]) }
            return nil
        }

        // Get all windows on this space
        let windowsOnSpace = space.windows.compactMap { windowID -> WindowState? in
            state.windows[String(windowID)]
        }.filter { $0.isOrderedIn && !$0.isMinimized }

        if windowsOnSpace.isEmpty {
            return nil
        }

        // Find internal boundaries between windows
        // An internal boundary exists where two windows share an edge

        // Group windows and find vertical boundaries (between columns)
        for window in windowsOnSpace {
            let rightEdge = window.frame.maxX

            // Find windows to the right of this one (sharing the vertical edge)
            for other in windowsOnSpace where other.id != window.id {
                let leftEdge = other.frame.minX

                // Check if they share a vertical boundary (right edge of window ~ left edge of other)
                if abs(rightEdge - leftEdge) < 20 {
                    // Check if they overlap vertically
                    if window.frame.maxY > other.frame.minY && window.frame.minY < other.frame.maxY {
                        // Found a vertical boundary
                        let boundaryX = (rightEdge + leftEdge) / 2

                        // Check if point is near this boundary
                        if abs(point.x - boundaryX) < threshold {
                            // Check if point is within the vertical range
                            let minY = max(window.frame.minY, other.frame.minY)
                            let maxY = min(window.frame.maxY, other.frame.maxY)
                            if point.y >= minY && point.y <= maxY {
                                // Determine direction: cursor is on right of left window, or left of right window
                                let edge: ResizeEdge = point.x < boundaryX ? .right : .left

                                Task { await JSONLogger.shared.log("edge.detect", data: [
                                    "type": "cell",
                                    "edge": edge.rawValue,
                                    "distance": abs(point.x - boundaryX)
                                ]) }

                                return EdgeHit(
                                    resizeType: .cell,
                                    targetID: "column",  // Generic cell boundary ID
                                    edge: edge,
                                    distance: abs(point.x - boundaryX)
                                )
                            }
                        }
                    }
                }
            }

            // Find windows below this one (sharing the horizontal edge)
            let bottomEdge = window.frame.maxY

            for other in windowsOnSpace where other.id != window.id {
                let topEdge = other.frame.minY

                // Check if they share a horizontal boundary
                if abs(bottomEdge - topEdge) < 20 {
                    // Check if they overlap horizontally
                    if window.frame.maxX > other.frame.minX && window.frame.minX < other.frame.maxX {
                        // Found a horizontal boundary
                        let boundaryY = (bottomEdge + topEdge) / 2

                        // Check if point is near this boundary
                        if abs(point.y - boundaryY) < threshold {
                            // Check if point is within the horizontal range
                            let minX = max(window.frame.minX, other.frame.minX)
                            let maxX = min(window.frame.maxX, other.frame.maxX)
                            if point.x >= minX && point.x <= maxX {
                                // Determine direction
                                let edge: ResizeEdge = point.y < boundaryY ? .bottom : .top

                                Task { await JSONLogger.shared.log("edge.detect", data: [
                                    "type": "cell",
                                    "edge": edge.rawValue,
                                    "distance": abs(point.y - boundaryY)
                                ]) }

                                return EdgeHit(
                                    resizeType: .cell,
                                    targetID: "row",
                                    edge: edge,
                                    distance: abs(point.y - boundaryY)
                                )
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Window Boundary Detection

    /// Detect if point is near a window split within a cell
    private func detectWindowBoundary(point: CGPoint, state: WindowManagerState) -> EdgeHit? {
        // For window boundaries, we look for windows that share a cell
        // and have internal split boundaries

        // Get windows on the active space
        guard let activeSpaceID = state.metadata.activeSpaceID else {
            return nil
        }

        let spaceKey = String(activeSpaceID)
        guard let space = state.spaces[spaceKey] else {
            return nil
        }

        let windowsOnSpace = space.windows.compactMap { windowID -> WindowState? in
            state.windows[String(windowID)]
        }.filter { $0.isOrderedIn && !$0.isMinimized }

        // Find pairs of windows that appear to be splits within the same cell
        // (same parent frame, adjacent)
        for window in windowsOnSpace {
            for other in windowsOnSpace where other.id != window.id {
                // Check if they're part of the same cell (similar bounds)
                // Two windows are split if they share 3 edges and differ on 1

                // Vertical split: same left/right, different top/bottom
                if abs(window.frame.minX - other.frame.minX) < 5 &&
                   abs(window.frame.maxX - other.frame.maxX) < 5 {
                    // Could be a vertical split
                    let gap = abs(window.frame.maxY - other.frame.minY)
                    let boundary = (window.frame.maxY + other.frame.minY) / 2

                    if gap < 20 && abs(point.y - boundary) < threshold {
                        if point.x >= window.frame.minX && point.x <= window.frame.maxX {
                            let edge: ResizeEdge = window.frame.maxY < other.frame.minY ? .bottom : .top

                            Task { await JSONLogger.shared.log("edge.detect", data: [
                                "type": "window",
                                "window": window.id,
                                "edge": edge.rawValue,
                                "distance": abs(point.y - boundary)
                            ]) }

                            return EdgeHit(
                                resizeType: .window,
                                targetID: String(window.id),
                                edge: edge,
                                distance: abs(point.y - boundary)
                            )
                        }
                    }
                }

                // Horizontal split: same top/bottom, different left/right
                if abs(window.frame.minY - other.frame.minY) < 5 &&
                   abs(window.frame.maxY - other.frame.maxY) < 5 {
                    // Could be a horizontal split
                    let gap = abs(window.frame.maxX - other.frame.minX)
                    let boundary = (window.frame.maxX + other.frame.minX) / 2

                    if gap < 20 && abs(point.x - boundary) < threshold {
                        if point.y >= window.frame.minY && point.y <= window.frame.maxY {
                            let edge: ResizeEdge = window.frame.maxX < other.frame.minX ? .right : .left

                            Task { await JSONLogger.shared.log("edge.detect", data: [
                                "type": "window",
                                "window": window.id,
                                "edge": edge.rawValue,
                                "distance": abs(point.x - boundary)
                            ]) }

                            return EdgeHit(
                                resizeType: .window,
                                targetID: String(window.id),
                                edge: edge,
                                distance: abs(point.x - boundary)
                            )
                        }
                    }
                }
            }
        }

        return nil
    }
}
