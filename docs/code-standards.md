<!-- base-commit: 89adf80 -->
<!-- generated: 2026-05-18 -->

# Code Standards

Project-specific conventions for theGrid (Swift-only macOS window manager). For repo layout, BFD command syntax, build/deploy, and known pitfalls see `CLAUDE.md` and `~/.grug-brain/hive/thegrid/project-architecture.md`.

---

## 1. Forbidden Patterns

**Never use `print()` for runtime logs** — JSONL events go through `jlog` / `JSONLogger.shared.log`.

```swift
// BAD — invisible to log pipelines, no event code, no structured data
print("space changed to \(newSpaceID)")

// GOOD — event code + structured data, lands in ~/.local/state/thegrid/thegrid-server.json
jlog("reconcile.space.change", data: ["space": newSpaceID, "display": displayUUID])
```

**Never write inline trailing comments** (project rule from `CLAUDE.md`). Comments live on their own line above the code.

```swift
// BAD
let threshold = 2  // two cycles before pruning

// GOOD
// two cycles before pruning — tolerates one transient AX failure
let threshold = 2
```

**Never use `Task {}` to call back into the same actor** (re-entrancy hazard). If you're already in an actor method, call directly.

```swift
// BAD — schedules a new task on the actor that will queue behind the current one
actor Foo {
    func update() {
        Task { await self.refresh() }
    }
}

// GOOD — direct await within the actor; serialized by the actor's executor
actor Foo {
    func update() async {
        await self.refresh()
    }
}
```

**Never strong-capture `self` in escaping closures** that outlive the receiver. Use `[weak self]` + `guard let self else { return }` (every Grid* module follows this).

---

## 2. Code Examples

### Event-driven handler (the dominant pattern)

```swift
// DO — from grid-server/Sources/GridServer/Grid/GridReconciler.swift
// Weak deps captured at init, structured jlog at start/end, defensive guards
// for module wiring (modules are wired post-init from main.swift).
private func handleDisplayConnected(_ displayUUID: String) async {
    jlog("reconcile.display.connect", data: ["display": displayUUID])

    // Short delay allows macOS to stabilize space/window state after reconnect.
    try? await Task.sleep(for: .milliseconds(500))

    let errors = await gridApply?.refreshAllDisplays(displayFilter: displayUUID) ?? []
    if !errors.isEmpty {
        jlog("warn.reconcile.display.connect.errors",
             data: ["display": displayUUID, "errorCount": errors.count])
    }
}
```

### Tracked async work with wake gate

```swift
// DO — from GridReconciler.handleSystemWake
// Stores the Task so commands can await it via awaitWakeCompletion(); clears
// the slot when done so subsequent commands fast-path through.
let task = Task { [weak self] in
    guard let self else { return }
    // ... multi-step work ...
    self.wakeValidationTask = nil
}
wakeValidationTask = task
await task.value
```

### Module-scoped error enum

```swift
// DO — from GridApply.swift:22
// One enum per Grid* module. LocalizedError so msgs propagate cleanly to
// CLI/MCP responses. Cases name the situation, not the symptom.
enum GridApplyError: Error, LocalizedError {
    case noLayout
    case layoutNotFound(String)
    case noDisplayBounds
    case allDisplaysFailed([GridDisplayError])

    var errorDescription: String? {
        switch self {
        case .noLayout: return "no layout applied"
        case .layoutNotFound(let id): return "layout not found: \(id)"
        case .noDisplayBounds: return "no display bounds"
        case .allDisplaysFailed(let errors): return "all displays failed: \(errors.count) errors"
        }
    }
}
```

---

## 3. Error Handling

Throw real errors via per-module enums conforming to `Error, LocalizedError`. No Result type wrapping. Public Grid* methods are `async throws`. Aggregate per-display errors via a returned `[GridDisplayError]` array (see `refreshAllDisplays`).

```swift
// From GridApply.refreshAllDisplays — returns errors instead of throwing when
// it's useful to keep going across multiple displays.
func refreshAllDisplays(displayFilter: String? = nil) async -> [GridDisplayError] {
    var errors: [GridDisplayError] = []
    for display in wmState.displays {
        do { try await applyLayout(...) }
        catch { errors.append(GridDisplayError(displayUUID: display.uuid, ..., error: error)) }
    }
    return errors
}
```

`jlog("warn.<scope>.<reason>", ...)` for non-fatal recoverable conditions. `jlog("err.<scope>", ...)` for fatal but caught. Throwing already gets logged at the catch site.

---

## 4. Imports & Dependency Direction

Standard Swift import order — Foundation, then AppKit/CoreGraphics/ApplicationServices, then internal package modules. No alphabetical enforcement.

Dependency direction inside `grid-server/Sources/GridServer/`:
- `Grid/*` modules → may depend on `StateManager`, `GridState`, `EventRouter`
- `EventRouter` → leaf (no deps on Grid/*)
- `StateManager` (actor) → leaf for state queries; routes to handlers via `EventRouter`
- `MessageHandler` → top of the stack; depends on Grid/* and StateManager
- Modules use `private weak var` for parent→child references; never strong, to avoid retain cycles in the wiring graph

---

## 5. Testing Patterns

Framework: XCTest. Tests in `grid-server/Tests/GridServerTests/`. Run via `swift test` from `grid-server/`.

Test names tied to plan done-when items use `test_DW_<phase>_<item>_<descriptor>`:

```swift
// From GridFocusRaceTests.swift — DW-1.1 maps to plan done-when item.
// Block comment above explains the scenario being validated.
func test_DW_1_1_race_branch_returns_true_when_actual_in_cell_windows() {
    let cellWindows: [UInt32] = [414, 1622]
    XCTAssertTrue(GridFocus.detectFocusRace(actual: 1622, cellWindows: cellWindows))
}
```

Pure-logic tests preferred (extract decision predicates as `static` helpers). Avoid AX/SkyLight calls in tests — mock at the boundary or test a pure helper.

Actor test helpers use the `_test_` prefix to signal they exist only for tests (not part of the actor's public contract):

```swift
// From StateValidator — seed data without real AX queries
func _test_seedOrphanCounts(_ counts: [UInt32: Int]) { ... }
func _test_orphanCountForWid(_ wid: UInt32) -> Int { ... }

// From StateManager — inject canned wmState without AX/SkyLight
func _test_setState(_ state: WindowManagerState) { ... }

// From GridReconciler — read private pending launch target for assertions
func _test_pendingLaunchTarget() -> PendingLaunchTarget? { ... }
```

Per project `CLAUDE.md`: 3-5 targeted tests per feature, prove the approach. Temporary tests are fine; delete after validation if not load-bearing.

---

## 6. Naming Conventions

Swift files: `PascalCase.swift` matching the primary type. `GridApply.swift` exports `GridApply`.

Event codes (jlog): dot-separated lowercase, scope-first.
- `reconcile.wake.start`, `validate.win.prune`, `srv.layout.restore`
- Warnings: `warn.<scope>.<reason>` (`warn.reconcile.display.connect.errors`)
- Errors: `err.<scope>` or `<scope>.err` (`cmd.err`, `action.err`)

Domain terms (load-bearing — match grug memo `thegrid/project-architecture.md`):
- `wid` = window ID (`UInt32`), `pid` = process ID, `sid` = space ID, `lid` = layout ID
- "cell" not "tile" / "pane"; "space" not "desktop"; "display" not "monitor" / "screen"

---

## 7. File Organization

```
grid-server/
├── Sources/
│   └── GridServer/
│       ├── Grid/                # Grid feature modules (one file per concern)
│       │   ├── GridReconciler.swift
│       │   ├── GridApply.swift
│       │   ├── StateValidator.swift
│       │   └── ...
│       ├── BFD/                 # Hotkey daemon
│       ├── Picker/              # Window picker overlay
│       ├── StateManager.swift   # Actor — single source of OS state
│       ├── EventRouter.swift    # Pub/sub for system events
│       └── main.swift           # Wiring
└── Tests/
    └── GridServerTests/         # XCTest, one file per module under test
```

New Grid features: one new file under `Grid/`. Wire dependencies in `main.swift`. Subscribe to events via `EventRouter.shared.register(self)` from a `StateEventHandler`.

---

## 8. Technology Decisions

- **Swift actors** for shared mutable state (`StateManager`, `GridState`, `EventRouter`, `StateValidator`). Never reach for `DispatchQueue` + locks for new state — extend an actor.
- **Private SkyLight APIs** are used (`SLSGetWindowBounds`, `_AXUIElementGetWindow`). They're declared via `@_silgen_name` at file scope. See `docs/MACOS_PRIVATE_API_SPEC.md` before adding new ones.
- **Three notification centers, three different events**: `NSWorkspace.shared.notificationCenter` (most app/space/wake events), `NotificationCenter.default` (`NSApplication.didChangeScreenParametersNotification`), and `DistributedNotificationCenter.default()` (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`). Subscribing to a lock notification on the NSWorkspace center will silently never fire. Pick the right center for the event; see `WorkspaceObserver.swift` for the existing precedent.
- **Border rendering on main queue only** (`SimpleBorderManager` uses CoreGraphics overlays). Hop with `await MainActor.run { … }` from actors.
- **No SwiftUI / Combine** — AppKit + structured concurrency only.

---

## 9. Exemplar Files

**`grid-server/Sources/GridServer/Grid/GridApply.swift`** — demonstrates:
- Module-scoped `Error, LocalizedError` enum (`GridApplyError`)
- `Sendable` value types for options/errors
- `// MARK:` section dividers
- Per-display error aggregation pattern (`refreshAllDisplays`)
- Weak-ref dependency wiring

**`grid-server/Sources/GridServer/Grid/GridReconciler.swift`** — demonstrates:
- `StateEventHandler` conformance, EventRouter wiring
- Action-lifecycle wrapper (`executeAction(label:body:)`) — copy this when adding new commands
- Wake-gate pattern (`wakeValidationTask` + `awaitWakeCompletion`)
- `[weak self]` + `guard let self else { return }` in long-lived tasks

**`grid-server/Sources/GridServer/Grid/StateValidator.swift`** — demonstrates:
- Actor + DispatchSourceTimer (background queue, leeway tolerance)
- Multi-pass validation (`pruneDeadWindows` → `pruneAXOrphanedWindows` → `deduplicateWindows` → `pruneDeadSpaces`)
- Defensive nil-skip when AX queries fail vs. confirmed-empty (`return nil` vs `return Set()`)
