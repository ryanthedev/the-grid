import Foundation

/// Whether to take focus back from a window the app chose instead of ours.
///
/// On ska, focusing Island's main window raised it, then Island handed key
/// focus to its own untitled 1082x660 window (not exposed to accessibility)
/// every time, so "focus Island" never landed. The grid's raise is correct; the
/// app overrides it a moment later. Checking shortly after and raising again
/// once wins that race without fighting the user.
enum FocusStealPolicy {
    static let verifyDelay: TimeInterval = 0.15
    static let maxRetries = 1

    /// - Parameters:
    ///   - want: the window the grid focused.
    ///   - got: the app's focused window now (nil when unreadable).
    ///   - appIsFrontmost: the target's app is still the active app; if the
    ///     user switched apps, the mismatch is theirs, not a steal.
    ///   - isLatestRequest: no newer focus request has been made since.
    static func shouldRetry(want: UInt32, got: UInt32?, appIsFrontmost: Bool,
                            isLatestRequest: Bool, retriesSoFar: Int) -> Bool {
        guard let got = got, got != want else { return false }
        return appIsFrontmost && isLatestRequest && retriesSoFar < maxRetries
    }
}

/// Monotonic focus-request counter, so a late check never undoes a newer focus.
enum FocusRequestSequence {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: UInt64 = 0

    static func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        current &+= 1
        return current
    }

    static func isLatest(_ seq: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seq == current
    }
}
