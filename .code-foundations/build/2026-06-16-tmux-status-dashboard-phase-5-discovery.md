# Discovery + Design: Phase 5 - AppDelegate wiring + lifecycle + observers

## Files Found

- `grid-notify/Sources/GridNotify/AppDelegate.swift` — 202 lines. Existing notify toggle observer, wiring pattern for window/vm/watcher/scriptManager. `applicationWillTerminate` already tears down watchers.
- `grid-notify/Sources/GridNotify/TmuxDashboardWindow.swift` — P3, exists.
- `grid-notify/Sources/GridNotify/TmuxDashboardViewModel.swift` — P3, `onRefreshRequested` closure hook, `load(_:)` on MainActor.
- `grid-notify/Sources/GridNotify/TmuxStatusWatcher.swift` — P2, `start()`/`stop()`/`onChange` callback.
- `grid-notify/Sources/GridNotify/TmuxStatusDriver.swift` — P4, `start()`/`stop()`/`refreshNow()`, flock mutex.
- `grid-notify/Sources/GridNotify/NotifyConfig.swift` — `NotifyConfig.Tmux` with `enabled`/`interval`/`repoDir`/`model`.
- `grid-notify/Tests/GridNotifyTests/TmuxDashboardTests.swift` — 64 tests pass; test pattern established.

## Current State

AppDelegate is fully implemented for the notification panel (notify toggle, watcher, scriptManager, animConfigWatcher). It does NOT yet have any tmux wiring. The four tmux components (window, viewModel, watcher, driver) are all built and tested in isolation but nothing wires them together in AppDelegate.

The existing `handleToggle` observer for `com.thegrid.notify.toggle` is the exact pattern to mirror for the two new tmux notifications.

## Gaps

- AppDelegate has no `setupTmuxDashboard()` method.
- No `com.thegrid.tmux.toggle` observer registered anywhere.
- No `com.thegrid.tmux.refresh` observer registered anywhere.
- `applicationWillTerminate` does not stop the tmux watcher or driver.
- The pure lifecycle decision logic (show+start vs hide+stop) is untested — it lives embedded in the AppKit boundary today (doesn't exist yet), so it must be extracted into a testable policy type.

## Code Standards

Key conventions from `docs/code-standards.md` that apply:

| Convention | Application |
|---|---|
| Sprout Method | New tmux wiring goes in `setupTmuxDashboard()` + small helpers, not inline in `applicationDidFinishLaunching` |
| `[weak self]` + `guard let self` | All escaping closures in the new observers |
| `jlog(...)` not `print()` | All log output through jlog with dot-separated event codes |
| No inline trailing comments | All comments on their own line above the code |
| Decision predicates as pure policy enums | `TmuxDashboardLifecyclePolicy` with named result enum, zero I/O, unit-testable |
| `_test_` prefix for test hooks | Any hooks exposed for test introspection |

## Test Infrastructure

- Framework: XCTest, `@testable import GridNotify`
- Tests in `grid-notify/Tests/GridNotifyTests/`
- 64 tests pass; the pattern is established in `TmuxStatusDriverTests.swift` and `TmuxDashboardTests.swift`
- AppDelegate is live AppKit — untestable directly. The welc-legacy-code skill prescribes Sprout Method: new logic is extracted into `setupTmuxDashboard()` and into a pure `TmuxDashboardLifecyclePolicy` that IS unit-testable.
- The lifecycle policy tests (`TmuxLifecyclePolicyTests.swift`) will cover the branch logic without touching AppKit.
- DW items for the live AppKit path (showing/hiding window, DistributedNotification observers) are manual-check items or validated via the policy tests.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-5.1 | `com.thegrid.tmux.toggle` shows the dashboard and starts driver+watcher; second toggle hides it and stops the driver | COVERED | `test_DW_5_1_policy_showWhenHidden_returnsShowAndStart`, `test_DW_5_1_policy_hideWhenVisible_returnsHideAndStop` (pure policy tests; AppKit path is manual-check) |
| DW-5.2 | With dashboard open, state-file change updates the tree live (watcher→viewModel) | COVERED | `test_DW_5_2_watcherOnChange_callsViewModelLoad` — integration test: watcher onChange → viewModel.load(_:) on MainActor |
| DW-5.3 | `com.thegrid.tmux.refresh` and in-view button both invoke `driver.refreshNow()` | COVERED | `test_DW_5_3_onRefreshRequested_callsDriverRefreshNow` (callback wiring test); `test_DW_5_3_policy_refresh_doesNotChangeVisibility` (policy test for refresh notification) |
| DW-5.4 | Hiding the window stops the driver (no further claude spawns); terminate releases the lock | COVERED | `test_DW_5_4_policy_hide_stopsDriver` (policy); `test_DW_5_4_terminate_stopsDriverAndWatcher` (integration: stop() on driver releases flock, verified via _test_isRunning) |

**All items COVERED:** YES

## Design Decisions

### 1. Pure lifecycle policy enum (welc + code-standards requirement)

The toggle handler has one decision: given the window's current visibility, should we show+start or hide+stop? This is extracted into:

```swift
enum TmuxDashboardAction { case showAndStart, hideAndStop }

enum TmuxDashboardLifecyclePolicy {
    static func action(windowVisible: Bool) -> TmuxDashboardAction
}
```

This follows `SpaceMigrationPolicy`, `FocusOwnershipPolicy` etc. from code-standards. It carries no I/O, no AppKit, and is unit-testable. The AppDelegate toggle handler calls the policy, then executes the I/O branch.

### 2. Sprout Method: `setupTmuxDashboard()` only called when `config.tmux.enabled == true`

```swift
// In applicationDidFinishLaunching:
if config.tmux.enabled {
    setupTmuxDashboard(config: config.tmux, theme: theme)
}
```

When disabled, zero cost — no observer registration, no window, no driver. When enabled, `setupTmuxDashboard` creates all four components and wires them.

### 3. Stored properties for the tmux subsystem

AppDelegate gets four new optional properties:
```swift
private var tmuxDashboardWindow: TmuxDashboardWindow?
private var tmuxViewModel: TmuxDashboardViewModel?
private var tmuxWatcher: TmuxStatusWatcher?
private var tmuxDriver: TmuxStatusDriver?
```

### 4. Toggle observer mirrors existing notify observer exactly

```swift
DistributedNotificationCenter.default().addObserver(
    self,
    selector: #selector(handleTmuxToggle),
    name: NSNotification.Name("com.thegrid.tmux.toggle"),
    object: nil
)
```

`handleTmuxToggle` dispatches to MainActor, calls `TmuxDashboardLifecyclePolicy.action(windowVisible:)`, then branches on the result.

### 5. watcher→viewModel live update wired in setupTmuxDashboard

```swift
watcher.onChange = { [weak viewModel] data in
    Task { @MainActor in
        viewModel?.load(data)
    }
}
```

Note: `TmuxStatusWatcher.reloadAndNotify` already dispatches onChange to the main thread via `DispatchQueue.main.async`. So the watcher callback is already on main. We still wrap in `Task { @MainActor in }` to satisfy the `@MainActor` annotation on `TmuxDashboardViewModel.load(_:)` — this is the correct bridging pattern.

Actually — since `onChange` is already called on the main queue (by the watcher's `DispatchQueue.main.async`), and `@MainActor` isolation is compatible with being on the main thread, we can call `viewModel?.load(data)` directly in the closure body. The `Task { @MainActor }` would create a new async hop. The direct call is cleaner and matches the existing `NotificationFileWatcher.onNotification` pattern which calls `vm?.refreshNotifications()` directly.

### 6. applicationWillTerminate teardown order

```swift
tmuxWatcher?.stop()
tmuxDriver?.stop()
```

Watcher before driver (stops new file-change callbacks before stopping the driver that would write the file).

### 7. Immediate load on show

When toggle shows the window, load the current status immediately (so the tree is populated before user sees the window). The watcher's `start()` already calls `reloadAndNotify()` on first open — no separate initial load needed. Watcher start is sufficient.

## Prerequisites

- [x] `TmuxDashboardWindow`, `TmuxDashboardViewModel` exist (P3)
- [x] `TmuxStatusWatcher` exists (P2)
- [x] `TmuxStatusDriver` exists (P4)
- [x] `NotifyConfig.Tmux` with `enabled` field exists (P2)
- [x] All 64 existing tests pass

## Recommendation

BUILD — all prerequisites met, no gaps, clean path forward.
