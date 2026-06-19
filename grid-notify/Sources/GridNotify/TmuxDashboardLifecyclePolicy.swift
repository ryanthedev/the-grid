import Foundation

// MARK: - TmuxDashboardAction

// Named result for the toggle lifecycle decision.
// Never a bare Bool — named results make call sites self-documenting.
enum TmuxDashboardAction: Equatable {
    // Show the dashboard window, start the watcher and driver.
    case showAndStart
    // Hide the dashboard window, stop the driver (cost guard).
    case hideAndStop
}

// MARK: - TmuxDashboardLifecyclePolicy

// Pure decision module: given the current window visibility,
// decide what the toggle notification should do.
//
// No I/O. No AppKit. No actor isolation.
// Fully unit-testable off the AppKit boundary (welc seam).
//
// Mirrors the pattern of SpaceMigrationPolicy, FocusOwnershipPolicy, etc.
enum TmuxDashboardLifecyclePolicy {

    // Returns the action the toggle handler should execute.
    //
    // - windowVisible: true when the dashboard window is currently visible
    //   (isVisible == true).
    static func action(windowVisible: Bool) -> TmuxDashboardAction {
        if windowVisible {
            return .hideAndStop
        } else {
            return .showAndStart
        }
    }
}
