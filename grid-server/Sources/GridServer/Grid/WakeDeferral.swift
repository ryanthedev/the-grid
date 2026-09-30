//
// WakeDeferral.swift
// GridServer
//
// Holds wake work until the screen is unlocked.
//
// At the login screen macOS reports every normal window as off-screen, and AX
// answers are unreliable. A window rescan there caches properties the poll
// never corrects (isHidden latches from kCGWindowIsOnscreen; a wrong non-nil
// role is never requeried), so every window stops being tileable, and a layout
// refresh built on that rescan saves every cell empty. The grid stayed empty
// until the server was restarted.
//
// So: wake (or a display change) while locked only records that work is owed,
// and the unlock pays it once.
//

import Foundation

struct WakeDeferral {
    private(set) var locked = false
    private(set) var pending = false

    mutating func lock() {
        locked = true
    }

    // Returns true when the caller should run its wake work now. While locked
    // it returns false and remembers to run on unlock instead.
    mutating func wake() -> Bool {
        if locked {
            pending = true
            return false
        }
        return true
    }

    // Returns true when a wake was deferred and the caller should run it now.
    mutating func unlock() -> Bool {
        locked = false
        let run = pending
        pending = false
        return run
    }
}
