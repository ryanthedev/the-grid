import Foundation
import CoreGraphics

// MARK: - GridNudge Errors

enum GridNudgeError: Error, LocalizedError {
    // getFocusedWindow returned 0, or required dependency is nil
    case noFocusedWindow
    // ManipulationContext.from() returned nil — window not in StateManager
    case windowNotFound
    // WindowManipulator AX call returned false
    case axFailed

    var errorDescription: String? {
        switch self {
        case .noFocusedWindow: return "no focused window"
        case .windowNotFound: return "window not found in state"
        case .axFailed: return "AX manipulation failed"
        }
    }
}

// MARK: - GridNudge

// Handles free-form window nudging: move and resize the focused window
// by a fixed step using AX manipulation, independent of the grid layout.
// Used by NudgeKeyHandler during @nudge mode sessions.
class GridNudge {

    // Step size in points applied per nudge action
    private static let defaultStep: CGFloat = 20

    // Dependencies (weak references, set via setup)
    private weak var gridState: GridState?
    private weak var stateManager: StateManager?
    private weak var windowManipulator: WindowManipulator?

    init() {}

    // Assign dependencies and log initialization.
    // Must be called before any move or resize operations.
    func setup(
        gridState: GridState,
        stateManager: StateManager,
        windowManipulator: WindowManipulator
    ) {
        self.gridState = gridState
        self.stateManager = stateManager
        self.windowManipulator = windowManipulator
        jlog("nudge.init")
    }

    // ============================================================
    // move: offset the focused window's position by defaultStep
    // in the given direction, leaving size unchanged.
    // ============================================================
    // spaceID: active space, resolved once by GridCommandRouter
    //          and passed through the NudgeKeyHandler callback.
    // direction: which way to move (left/right = x-axis, up/down = y-axis)
    // Throws: noFocusedWindow if no window is focused or deps are nil,
    //         windowNotFound if the window is absent from StateManager,
    //         axFailed if the AX position call fails.
    // ============================================================

    // Returns (windowID, newFrame) so caller can update borders
    @discardableResult
    func move(spaceID: String, direction: GridDirection) async throws -> (UInt32, CGRect) {
        guard let gridState = gridState,
              let windowManipulator = windowManipulator else {
            throw GridNudgeError.noFocusedWindow
        }

        let wid = await gridState.getFocusedWindow(spaceID: spaceID)
        guard wid != 0 else {
            throw GridNudgeError.noFocusedWindow
        }

        guard let context = await ManipulationContext.from(windowID: wid) else {
            throw GridNudgeError.windowNotFound
        }

        let step = GridNudge.defaultStep
        let currentFrame = context.frame ?? .zero

        let newOrigin: CGPoint
        switch direction {
        case .left:
            newOrigin = CGPoint(x: currentFrame.origin.x - step, y: currentFrame.origin.y)
        case .right:
            newOrigin = CGPoint(x: currentFrame.origin.x + step, y: currentFrame.origin.y)
        case .up:
            newOrigin = CGPoint(x: currentFrame.origin.x, y: currentFrame.origin.y - step)
        case .down:
            newOrigin = CGPoint(x: currentFrame.origin.x, y: currentFrame.origin.y + step)
        }

        let success = await windowManipulator.moveWindow(context: context, to: newOrigin)
        guard success else {
            throw GridNudgeError.axFailed
        }

        let newFrame = CGRect(origin: newOrigin, size: currentFrame.size)
        jlog("nudge.move", data: ["wid": wid, "dir": direction.rawValue, "x": newOrigin.x, "y": newOrigin.y])
        return (wid, newFrame)
    }

    // ============================================================
    // resize: grow or shrink the focused window edge by defaultStep.
    // ============================================================
    // spaceID: active space, resolved once by GridCommandRouter.
    // direction: which edge moves (per plan spec):
    //   left  -> origin.x += step, width  -= step  (shrink from left edge)
    //   right -> width  += step               (grow rightward)
    //   up    -> origin.y += step, height -= step  (shrink from top edge)
    //   down  -> height += step               (grow downward)
    // setWindowFrame is used (not moveWindow + resizeWindow) because left/up
    // need both origin and size changed atomically in one StateManager update.
    // Throws: noFocusedWindow, windowNotFound, axFailed (same as move).
    // ============================================================

    // Returns (windowID, newFrame) so caller can update borders
    @discardableResult
    func resize(spaceID: String, direction: GridDirection) async throws -> (UInt32, CGRect) {
        guard let gridState = gridState,
              let windowManipulator = windowManipulator else {
            throw GridNudgeError.noFocusedWindow
        }

        let wid = await gridState.getFocusedWindow(spaceID: spaceID)
        guard wid != 0 else {
            throw GridNudgeError.noFocusedWindow
        }

        guard let context = await ManipulationContext.from(windowID: wid) else {
            throw GridNudgeError.windowNotFound
        }

        let step = GridNudge.defaultStep
        let currentFrame = context.frame ?? .zero

        let newFrame: CGRect
        switch direction {
        case .left:
            newFrame = CGRect(
                x: currentFrame.origin.x + step,
                y: currentFrame.origin.y,
                width: currentFrame.size.width - step,
                height: currentFrame.size.height
            )
        case .right:
            newFrame = CGRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: currentFrame.size.width + step,
                height: currentFrame.size.height
            )
        case .up:
            newFrame = CGRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y + step,
                width: currentFrame.size.width,
                height: currentFrame.size.height - step
            )
        case .down:
            newFrame = CGRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: currentFrame.size.width,
                height: currentFrame.size.height + step
            )
        }

        let success = await windowManipulator.setWindowFrame(context: context, frame: newFrame)
        guard success else {
            throw GridNudgeError.axFailed
        }

        jlog("nudge.resize", data: ["wid": wid, "dir": direction.rawValue, "w": newFrame.size.width, "h": newFrame.size.height])
        return (wid, newFrame)
    }
}
