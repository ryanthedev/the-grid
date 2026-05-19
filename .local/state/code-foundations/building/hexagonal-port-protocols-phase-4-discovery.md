# Discovery + Design: Phase 4 - GridStorage Port

## Files Found

- `Sources/GridServer/Grid/GridState.swift` — actor; holds `statePath: String`, `saveTask`, `isDirty`, `debounceInterval`; methods: `init()`, `load()`, `persistNow()`, `flush()`, `reset()`, `markDirty()` (all persistence-related)
- `Sources/GridServer/main.swift` — creates `GridState()` with no args, calls `await gridState.load()` inside a `Task {}`
- `Sources/GridServer/Ports/StateProvider.swift`, `BorderRendering.swift`, `WindowController.swift` — pattern references
- `Tests/GridServerTests/StateProviderTests.swift`, `BorderRenderingTests.swift`, `WindowControllerTests.swift` — test pattern references

No `Ports/GridStorage.swift` exists yet. No `FileGridStorage.swift` exists yet. No `GridStorageTests.swift` exists yet.

## Current State

GridState is a 925-line actor. Persistence lives in three private methods:

- `load()` — synchronous, reads `statePath` from disk, decodes `GridRuntimeStateData`, mutates `spaces`/`displaySpaces`/`lastUpdated` actor fields directly. Already called from `main.swift` as `await gridState.load()`.
- `markDirty()` — sets `isDirty = true`, cancels/replaces `saveTask`, schedules debounce via `Task.sleep`
- `persistNow()` — synchronous, encodes current `spaces`/`displaySpaces`/`lastUpdated` into `GridRuntimeStateData`, writes to `statePath.tmp`, atomically renames to `statePath`
- `flush()` / `reset()` — call `persistNow()` directly

The date encoders/decoders (two static `DateFormatter` statics) are used in both load and save paths — they must move with the file I/O code.

## Gaps vs. Plan Assumptions

**Assumption: "Debounce timer works correctly when save is delegated" (HIGH confidence)**

VERIFIED CORRECT. The debounce timer (`markDirty` → `saveTask` → `persistNow`) is actor-internal scheduling, not I/O. After extraction, `persistNow()` will call `await storage.save(stateData)` instead of doing file I/O directly. The debounce pattern is unchanged. `persistNow()` itself becomes `async` to await the storage call; the `saveTask` wrapping the `Task.sleep` + `persistNow()` already runs inside a `Task {}` so making `persistNow` async is compatible.

One design adjustment: `persistNow()` currently calls self from inside a `Task {}` spawned by `markDirty()`. The code is:
```swift
saveTask = Task {
    try await Task.sleep(for: debounceInterval)
    self.persistNow()  // synchronous call on actor
}
```
After making `persistNow()` async:
```swift
saveTask = Task {
    try await Task.sleep(for: debounceInterval)
    await self.persistNow()  // async call on actor
}
```
This is valid — calling an async actor method from a Task is fine (the task re-enters the actor).

No UPDATE_PLAN needed.

## Code Standards

- Comments on own line above code, never inline trailing
- `private weak var` for dependency storage (but GridStorage is not an AnyObject protocol — GridState owns it strongly as `any GridStorage`)
- `jlog()` for logging, no `print()`
- `_test_` prefix for test-only helpers on actors
- Test names: `test_DW_4_N_descriptor`
- `@unchecked Sendable` on test fakes (single-threaded tests)
- Protocol modelled after StateProvider / BorderRendering: `protocol GridStorage: Sendable` (no AnyObject — storage is value-like, not a class reference)

## Test Infrastructure

XCTest, `@testable import GridServer`. Pattern from Phases 1-3:
- Mock/fake defined at top of test file alongside tests
- `_test_setup()` or `init` injection on the actor under test
- Test names tied to DW-IDs

GridState is an actor and currently has no injectable init for storage. Need to add `init(storage: any GridStorage)` or a `_test_setup` variant. Given that `main.swift` uses `GridState()` with no args, the cleanest approach is to add an overloaded init that accepts `any GridStorage`, keeping the default init using `FileGridStorage(path: ...)`.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-4.1 | `Ports/GridStorage.swift` exists with `protocol GridStorage: Sendable` | COVERED | `test_DW_4_1_protocol_exists_with_load_and_save` (compile-time conformance + exercise) |
| DW-4.2 | `FileGridStorage` extracted with atomic-write logic from current `persistNow` | COVERED | Compile-time + `test_DW_4_2_file_storage_roundtrip` if file ops are in scope; covered by build success + existing tests running against production code path |
| DW-4.3 | GridState accepts `any GridStorage` at init, delegates load/save | COVERED | `test_DW_4_3_gridstate_delegates_save_to_storage` + `test_DW_4_3_gridstate_delegates_load_from_storage` |
| DW-4.4 | `InMemoryGridStorage` test fake stores data in memory | COVERED | `test_DW_4_4_in_memory_storage_save_load_roundtrip`, `test_DW_4_4_in_memory_storage_load_empty` |
| DW-4.5 | At least 2 tests: save-load roundtrip preserves state, load with no prior save returns nil/empty | COVERED | `test_DW_4_5_roundtrip_preserves_state`, `test_DW_4_5_load_empty_returns_nil` |
| DW-4.6 | `swift build` succeeds, existing tests pass | COVERED | Run at end of phase |

**All items COVERED:** YES

## Design Decisions

### Protocol shape

Two approaches:

**A: `load() async throws -> GridRuntimeStateData?` — returns Optional (nil = no prior state)**
- Caller (GridState) decides what to do with nil (use defaults = current behavior)
- Error thrown = I/O failure (corrupt file, permission error)
- Clean separation: storage knows nothing about defaults

**B: `load() async throws -> GridRuntimeStateData` — returns non-Optional with defaults baked in**
- Storage either returns data or creates a default
- Couples persistence to domain defaults

**Chosen: A** — nil = no prior state. GridState keeps its existing nil-handling (use empty defaults). Errors thrown for I/O failures.

`save(_ data: GridRuntimeStateData) async throws` — straightforward, throws on I/O error.

### GridState init injection

**A: `init(storage: any GridStorage)` + default no-arg `init()` that creates `FileGridStorage`**
- Clean: production path unchanged (`GridState()`)
- Test path: `GridState(storage: InMemoryGridStorage())`

**B: `_test_setStorage(_ storage: any GridStorage)` injected post-init**
- Awkward: storage is needed at `load()` time

**Chosen: A** — overloaded init. Default init creates `FileGridStorage(path: XDG.stateHome + "/thegrid/state.json")`. Test init takes `any GridStorage`.

### FileGridStorage placement

A dedicated file `Sources/GridServer/Ports/FileGridStorage.swift` alongside the protocol. This follows the pattern of keeping port-adjacent types together. The date formatters (currently static on GridState) move to `FileGridStorage`.

### Sendable vs AnyObject on protocol

StateProvider, BorderRendering, WindowController all use `protocol P: AnyObject, Sendable` because they're used as `weak var` references (class-only). GridStorage is different: GridState *owns* its storage (not weak). It's more like a value-level service — but since we want `any GridStorage` to cross actor boundaries (passed at init time from non-actor context), `Sendable` is required. `AnyObject` is NOT needed — `InMemoryGridStorage` can be a struct-like actor or a class. We'll make it a final class with `@unchecked Sendable` (tests are single-threaded), and `FileGridStorage` a struct or final class.

Final decision: `protocol GridStorage: Sendable` (no AnyObject) — allows struct conformers in future. `FileGridStorage` will be a `final class` that is `Sendable` (immutable after init, all operations use async file I/O with no shared mutable state).

Actually, `FileGridStorage` encodes/decodes with static formatters and writes to a fixed path — it's stateless after init. It can be `struct` + `Sendable`.

`InMemoryGridStorage` needs mutable state (stored data) across calls, so it must be a class or actor. Using `final class` + `@unchecked Sendable` (single-threaded test usage) is consistent with MockWindowController pattern.

## Prerequisites

- [x] Phase 1 (StateProvider) completed, Ports/ directory exists
- [x] Phase 2 (BorderRendering) completed
- [x] Phase 3 (WindowController) completed  
- [x] 103 tests pass, build clean
- [x] GridRuntimeStateData is Codable (confirmed in GridState.swift lines 4-80)
- [x] `load()` is already called as `await gridState.load()` in main.swift (actor method, no signature change needed externally)

## Recommendation

BUILD
