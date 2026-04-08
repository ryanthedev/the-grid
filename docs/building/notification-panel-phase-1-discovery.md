# Discovery: Phase 1 - Notification data model and persistence

## Files Found

- `grid-server/Sources/GridServer/Grid/GridState.swift` -- persistence pattern reference (exists)
- `grid-server/Sources/GridServer/StateManager.swift` -- actor pattern reference (exists)
- `grid-server/Sources/GridServer/XDG.swift` -- XDG path helper (exists)
- `grid-server/Sources/GridServer/JSONLogger.swift` -- logging helper (exists)
- `grid-server/Tests/GridServerTests/` -- test directory with existing XCTest tests (exists)
- `grid-server/Package.swift` -- test target `GridServerTests` already wired (exists)

## Current State

No `Notifications/` directory exists. This is a clean-slate creation.

The persistence pattern in `GridState.swift` is well-established and directly applicable:
- Actor-based state isolation (no locks needed)
- Codable structs for data (not classes)
- Debounced writes: `markDirty()` cancels prior `saveTask`, schedules new `Task.sleep` for 500ms
- Atomic writes: write to `.tmp` file, then `rename()` to destination
- `flush()` for immediate write on shutdown
- `XDG.stateHome` for path resolution
- `jlog()` for all logging

The test pattern uses `XCTest` with `@testable import GridServer`. Tests are straightforward struct/encode/decode tests. No `async` test infrastructure is visibly needed for pure model tests, but the `NotificationStore` is an actor so tests will need `await`.

## Gaps

None. No files to modify for this phase -- only files to create:
1. `grid-server/Sources/GridServer/Notifications/Notification.swift` -- model + action types
2. `grid-server/Sources/GridServer/Notifications/NotificationStore.swift` -- actor
3. `grid-server/Tests/GridServerTests/NotificationStoreTests.swift` -- unit tests

The `Notifications/` directory will be created by creating these files. The Swift package system discovers files by directory; no `Package.swift` changes needed since `GridServer` target uses `path: "Sources/GridServer"` which includes all subdirectories.

## Prerequisites

- [x] Reference file `GridState.swift` exists and is readable
- [x] `XDG.stateHome` available for path construction
- [x] `jlog()` available for logging
- [x] Test target `GridServerTests` exists and compiles
- [x] No external dependencies required (Foundation only)
- [x] No Phase 0 blocking items

## Recommendation

BUILD

Create three new files:
- `Notifications/Notification.swift` -- model definitions
- `Notifications/NotificationStore.swift` -- actor with CRUD, filtering, bulk ops, persistence
- `Tests/GridServerTests/NotificationStoreTests.swift` -- unit tests covering all done-when criteria
