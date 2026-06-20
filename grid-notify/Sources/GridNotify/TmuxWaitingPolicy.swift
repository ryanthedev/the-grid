import Foundation

// MARK: - TmuxWaitingDiff

// Named result of diffing one tmux load against the prior waiting set.
// newlyWaiting: windows that entered .waiting this load (waiting now AND not
// previously waiting) — these fire exactly one notification each.
// waitingNow: every target currently in .waiting — becomes the next load's
// previousWaiting, so a target that vanishes simply drops out and re-arms.
struct TmuxWaitingDiff: Equatable {
    let newlyWaiting: [TmuxWindow]
    let waitingNow: Set<String>

    static func == (lhs: TmuxWaitingDiff, rhs: TmuxWaitingDiff) -> Bool {
        lhs.waitingNow == rhs.waitingNow
            && lhs.newlyWaiting.map(\.target) == rhs.newlyWaiting.map(\.target)
    }
}

// MARK: - TmuxWaitingPolicy

// Pure decision predicate for the waiting-transition edge. No I/O, no actor
// isolation, no side effects — unit-testable off the AppKit/store boundary.
// The viewModel owns the mutable previousWaiting state; this only computes.
enum TmuxWaitingPolicy {

    // Diff the current windows against the prior waiting set.
    // newlyWaiting preserves the input window order for deterministic emission.
    static func diff(previousWaiting: Set<String>, windows: [TmuxWindow]) -> TmuxWaitingDiff {
        let waitingWindows = windows.filter { $0.statusKind == .waiting }
        let waitingNow = Set(waitingWindows.map(\.target))
        let newlyWaiting = waitingWindows.filter { !previousWaiting.contains($0.target) }
        return TmuxWaitingDiff(newlyWaiting: newlyWaiting, waitingNow: waitingNow)
    }
}
