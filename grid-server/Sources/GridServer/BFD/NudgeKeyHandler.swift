import Foundation
import CoreGraphics
import AppKit

// MARK: - NudgeAction

/// An action emitted by the nudge key handler for each relevant keypress.
/// The caller receives this via the `onNudge` callback and dispatches accordingly.
enum NudgeAction {
    // Move the focused window one step in `direction`
    case move(GridDirection)
    // Resize the focused window's cell boundary in `direction`
    case resize(GridDirection)
    // Exit nudge mode (Escape)
    case exit
}

// MARK: - Key table

// Maps hardware key code to a direction.
// Escape is handled separately.
//
// Key codes (US layout):
//   13 = W, 1 = S, 0 = A, 2 = D
//   126 = Up arrow, 125 = Down arrow, 123 = Left arrow, 124 = Right arrow
private let nudgeKeyDirection: [UInt32: GridDirection] = [
    13: .up,    1: .down,   0: .left,   2: .right,
    126: .up, 125: .down, 123: .left, 124: .right,
]

private let escapeKeyCode: UInt32 = 53

// MARK: - NudgeKeyHandler

/// Captures keyboard events during an active nudge session.
///
/// Installs a CGEventTap on the main run loop that intercepts keyDown events
/// and translates them into NudgeAction values delivered via `onNudge`.
/// The tap is active only between `start()` and `stop()` — typically seconds
/// to minutes — so no health-check timer is needed.
///
/// Callback thread guarantee: `onNudge` fires on the main thread because
/// the run loop source is added to the main run loop. No dispatch to main
/// is required in the callback.
///
/// Usage:
///   let handler = NudgeKeyHandler()
///   handler.onNudge = { action in … }
///   guard handler.start() else { /* accessibility permission denied */ }
///   // … user nudges windows …
///   handler.stop()
class NudgeKeyHandler {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Track currently held direction keys for diagonal support
    private var heldDirections: Set<GridDirection> = []

    /// Called on the main thread for each relevant keypress.
    /// Receives `.exit` on Escape, `.move(dir)` on WASD/arrows,
    /// and `.resize(dir)` on Shift+WASD/Shift+arrows.
    /// For diagonal movement, called once per held direction on each keyDown.
    var onNudge: ((NudgeAction) -> Void)?

    init() {}

    deinit {
        // Safety net: release OS resources if caller forgot to call stop()
        stop()
    }

    // MARK: - Lifecycle

    /// Installs the CGEventTap and begins capturing keyboard events.
    ///
    /// Returns `true` on success. Returns `false` if the tap cannot be created,
    /// which typically means Accessibility permission has not been granted.
    /// Calling `start()` while already running is a no-op that returns `true`.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: nudgeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            JSONLogger.shared.log("nudge.err.tap")
            return false
        }

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            eventTap = nil
            return false
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        JSONLogger.shared.log("nudge.start")
        return true
    }

    /// Disables and tears down the CGEventTap and its run loop source.
    ///
    /// Safe to call multiple times or when not started.
    func stop() {
        guard let tap = eventTap else { return }

        heldDirections.removeAll()
        CGEvent.tapEnable(tap: tap, enable: false)

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        CFMachPortInvalidate(tap)
        eventTap = nil

        JSONLogger.shared.log("nudge.stop")
    }

    // MARK: - Private

    /// Processes a raw CGEvent from the tap callback.
    ///
    /// Returns `nil` to consume the event (prevent delivery to the focused app),
    /// or `Unmanaged.passUnretained(event)` to pass it through unchanged.
    fileprivate func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // macOS disabled the tap because event processing was too slow.
        // Re-enable immediately and pass through — this is not a real key event.
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            JSONLogger.shared.log("nudge.timeout.reenable")
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))

        // keyUp: remove direction from held set, consume if it was a nudge key
        if type == .keyUp {
            if let dir = nudgeKeyDirection[keyCode] {
                heldDirections.remove(dir)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Escape always exits, regardless of modifier state
        if keyCode == escapeKeyCode {
            heldDirections.removeAll()
            onNudge?(.exit)
            return nil
        }

        // Unknown key — pass through to the focused app
        guard let direction = nudgeKeyDirection[keyCode] else {
            return Unmanaged.passUnretained(event)
        }

        // Track held direction
        heldDirections.insert(direction)

        // Shift selects resize; bare key selects move
        let isShift = event.flags.contains(.maskShift)

        // Fire action for all currently held directions (enables diagonal)
        for dir in heldDirections {
            let action: NudgeAction = isShift ? .resize(dir) : .move(dir)
            onNudge?(action)
        }

        // Consume: prevent the key from reaching the focused app
        return nil
    }
}

// MARK: - C callback bridge

// Top-level C function required by CGEvent.tapCreate.
// Bridges to the Swift instance method via the refcon pointer.
private let nudgeTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let handler = Unmanaged<NudgeKeyHandler>.fromOpaque(refcon).takeUnretainedValue()
    return handler.handleEvent(proxy: proxy, type: type, event: event)
}
