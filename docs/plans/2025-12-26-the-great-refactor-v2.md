# StateManager Actor Refactor Implementation Plan v2

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert StateManager from a DispatchQueue-based class to a Swift Actor to fix a critical race condition where `focusedWindowID` can be null even after focus events are processed.

**Architecture:** StateManager becomes an actor with compiler-enforced isolation. All public methods become async. MessageHandler and WindowManipulator wrap calls in Tasks to bridge sync handlers to async StateManager. EventRouter (already an actor) routes events to the StateManager actor.

**Tech Stack:** Swift 5.9+ Actors, async/await, macOS 14+ Sonoma, Private SkyLight APIs

---

## Bug Summary

**Root Cause:** `executeOnQueue` spawns unstructured `Task {}` inside `queue.async`, which runs on Swift's cooperative thread pool instead of the queue. `queue.sync` reads complete before the Task finishes, returning stale state.

**Fix:** Convert to Swift Actor where compiler enforces all access is serialized.

---

## Files to Modify

| File | Changes |
|------|---------|
| `StateManager.swift` | Convert class → actor, remove queue infrastructure |
| `MessageHandler.swift` | Wrap handlers in `Task {}` for async StateManager |
| `WindowManipulator.swift` | Make context methods async, update `ManipulationContext` |
| `MouseHandler.swift` | Wrap `getState()` call in Task |
| `main.swift` | Update initialization to use async |
| `ApplicationObserver.swift` | Remove dead `stateManager` property |
| `WorkspaceObserver.swift` | Remove dead `stateManager` property |

---

## Task 1: Create Backup Branch

**Files:** None (git only)

**Step 1: Verify build compiles**

```bash
cd /Users/r/repos/theGrid/.worktrees/the-great-refactor && swift build -c debug 2>&1 | tail -5
```
Expected: Build succeeded

**Step 2: Create backup branch**

```bash
git checkout -b feature/the-great-refactor-backup && git checkout feature/the-great-refactor
```

**Step 3: Commit current state**

```bash
git add -A && git status
```

---

## Task 2: Convert StateManager Class to Actor

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Change class to actor (line ~16)**

```swift
// Before
class StateManager: StateEventHandler {

// After
actor StateManager: StateEventHandler {
```

**Step 2: Fix singleton pattern (lines ~18-22)**

```swift
// Before
    // MARK: - Singleton
    static let shared = StateManager()

// After
    // MARK: - Shared Instance
    // Thread-safe lazy initialization - actor ensures all access is serialized
    private static let _shared = StateManager()
    static var shared: StateManager { _shared }
```

**Step 3: Build to see errors (expected)**

```bash
swift build 2>&1 | head -30
```

---

## Task 3: Remove DispatchQueue Infrastructure

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Remove queue property and queueKey (lines ~25-27)**

Delete:
```swift
    private let queue = DispatchQueue(label: "com.grid.StateManager", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
```

**Step 2: Remove queue setup in init (line ~46)**

Delete:
```swift
        queue.setSpecific(key: queueKey, value: true)
```

**Step 3: Remove executeOnQueue helper (lines ~524-533)**

Delete entire function:
```swift
    private func executeOnQueue(_ operation: @escaping () async -> Void) {
        let span = CurrentSpan.current
        queue.async { [span] in
            Task {
                await CurrentSpan.$current.withValue(span) {
                    await operation()
                }
            }
        }
    }
```

**Step 4: Remove executeOnQueueSync helper (lines ~539-548)**

Delete entire function:
```swift
    private func executeOnQueueSync(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            operation()
        } else {
            queue.sync {
                operation()
            }
        }
    }
```

---

## Task 4: Fix Polling Timer

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift` (lines ~1095-1106)

**Step 1: Update startPolling to use global queue**

```swift
// Before
    func startPolling(interval: TimeInterval = 3.0) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.pollWindowState()
        }
        // ...
    }

// After
    func startPolling(interval: TimeInterval = 3.0) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.setEventHandler { [weak self] in
            Task {
                await self?.pollWindowState()
            }
        }
        // ...
    }
```

**Step 2: Make pollWindowState async if not already**

The function mutates `state` directly, which is fine within an actor method.

---

## Task 5: Convert Public State Access Methods

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Simplify getState() (line ~82)**

```swift
// Before
    func getState() -> WindowManagerState {
        return queue.sync {
            return state
        }
    }

// After
    func getState() -> WindowManagerState {
        return state
    }
```

Note: External callers will need `await StateManager.shared.getState()`.

**Step 2: getStateJSON() and getStateDictionary()**

These call `getState()` internally - no changes needed, they work with actor isolation.

---

## Task 6: Convert Public Mutation Methods

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Convert setFocusedWindow to async (line ~680)**

```swift
// Before
    func setFocusedWindow(_ windowID: UInt32) {
        executeOnQueueSync {
            self.state.metadata.focusedWindowID = windowID
            // ...
        }
        Task {
            // emit event
        }
    }

// After
    func setFocusedWindow(_ windowID: UInt32) async {
        state.metadata.focusedWindowID = windowID

        // Update active display
        let windowKey = String(windowID)
        if let window = state.windows[windowKey],
           !window.isMinimized,
           let display = displayForWindowFrame(window.frame) {
            state.metadata.activeDisplayUUID = display.uuid
        } else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            state.metadata.activeDisplayUUID = displayUUID as String
        }

        // Update active space
        if let window = state.windows[windowKey],
           let firstSpace = window.spaces.first {
            state.metadata.activeSpaceID = UInt64(firstSpace)
            let spaceKey = String(firstSpace)
            state.spaces[spaceKey]?.lastFocusedWindowID = windowID
        } else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            let querySpaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
            if querySpaceID != 0 {
                state.metadata.activeSpaceID = querySpaceID
                let spaceKey = String(querySpaceID)
                state.spaces[spaceKey]?.lastFocusedWindowID = windowID
            }
        }

        state.metadata.update()

        // Emit focusChanged event
        let focusState = FocusState(
            windowID: windowID,
            spaceID: state.metadata.activeSpaceID ?? 0,
            displayUUID: state.metadata.activeDisplayUUID ?? "",
            trigger: .manual
        )
        await EventRouter.shared.route(.focusChanged(focusState), from: .manual(reason: "cli-focus"))
    }
```

**Step 2: Simplify setWindowFrame (line ~733)**

```swift
// Before
    func setWindowFrame(_ windowID: UInt32, frame: CGRect) {
        executeOnQueueSync {
            // ...
        }
    }

// After
    func setWindowFrame(_ windowID: UInt32, frame: CGRect) {
        guard var window = state.windows[String(windowID)] else { return }
        window.frame = frame
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
    }
```

**Step 3: Simplify setWindowMinimized (line ~749)**

```swift
// After
    func setWindowMinimized(_ windowID: UInt32, minimized: Bool) {
        let key = String(windowID)
        guard var window = state.windows[key] else { return }
        window.isMinimized = minimized
        window.isHidden = minimized
        window.lastUpdated = Date()
        state.windows[key] = window
        state.metadata.update()
    }
```

---

## Task 7: Convert Event Handlers - executeOnQueue

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

For each handler using `executeOnQueue`, remove the wrapper and make async:

**Pattern:**
```swift
// Before
    private func handleWindowCreated(_ windowID: UInt32, pid: pid_t) {
        executeOnQueue {
            // body using self.state
        }
    }

// After
    private func handleWindowCreated(_ windowID: UInt32, pid: pid_t) async {
        // body using state (no self. needed)
    }
```

**Apply to these handlers:**
- `handleWindowCreated` (line ~1246)
- `handleWindowDestroyed` (line ~1317)
- `handleWindowFocused` (line ~1389)
- `handleWindowMinimized` (line ~1414)
- `handleWindowDeminimized` (line ~1428)
- `handleWindowSpaceAssignmentChanged` (line ~1449)
- `handleSpaceCreated` (line ~1468)
- `handleSpaceDestroyed` (line ~1479)
- `handleDisplayConnected` (line ~1495)
- `handleDisplayDisconnected` (line ~1504)
- `handleSpaceChanged` (line ~1522)
- `handleDisplayConfigurationChanged` (line ~1643)
- `handleApplicationLaunched` (line ~1668)
- `handleApplicationTerminated` (line ~1686)
- `handleApplicationActivated` (line ~1711)
- `handleApplicationHidden` (line ~1759)
- `handleApplicationUnhidden` (line ~1779)
- `handleSystemWoke` (line ~1802)

---

## Task 8: Convert Event Handlers - executeOnQueueSync

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Pattern:**
```swift
// Before
    private func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        executeOnQueueSync {
            guard var window = self.state.windows[String(windowID)] else { return }
            // ...
        }
    }

// After
    private func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        guard var window = state.windows[String(windowID)] else { return }
        window.frame = frame
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
    }
```

**Apply to:**
- `handleWindowMoved` (line ~1355)
- `handleWindowResized` (line ~1372)
- `handleWindowTitleChanged` (line ~1442)

---

## Task 9: Fix Actor Reentrancy in applyWindowFocus

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Problem:** `applyWindowFocus` has multiple await points where reentrancy could occur.

**Step 1: Make updateActiveDisplay and updateActiveSpace synchronous**

These methods mostly do state lookups and can be made synchronous:

```swift
// Change from async to sync where possible
    private func updateActiveDisplay(for windowID: UInt32, logChanges: Bool) {
        // Remove await calls, do state lookups synchronously
        let windowKey = String(windowID)
        guard let window = state.windows[windowKey] else { return }

        if let display = displayForWindowFrame(window.frame) {
            state.metadata.activeDisplayUUID = display.uuid
        }
        // ... rest without awaits
    }
```

**Step 2: If awaits are required, capture state before and verify after**

```swift
    private func applyWindowFocus(_ windowID: UInt32) async {
        // Capture current focus before any awaits
        let previousFocus = state.metadata.focusedWindowID

        state.metadata.focusedWindowID = windowID

        // Synchronous state updates (no reentrancy risk)
        updateActiveDisplaySync(for: windowID)
        updateActiveSpaceSync(for: windowID)

        state.metadata.update()

        // Only emit event if we're still the intended focus
        if state.metadata.focusedWindowID == windowID {
            // ... emit event
        }
    }
```

---

## Task 10: Update handle() Method Calls

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift` (lines ~105-198)

**Step 1: Add await to handler calls that are now async**

```swift
    func handle(_ event: StateEvent, context: EventContext) async throws {
        switch event {
        case .windowCreated(let windowID, let pid):
            await handleWindowCreated(windowID, pid: pid)  // Add await

        case .windowDestroyed(let windowID):
            await handleWindowDestroyed(windowID)  // Add await

        case .windowMoved(let windowID, let frame):
            handleWindowMoved(windowID, frame: frame)  // No await (sync)

        // ... etc
        }
    }
```

---

## Task 11: Convert start() Method

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift` (lines ~59-80)

```swift
// Before
    func start() {
        executeOnQueue {
            await self.refreshCompleteState()
            // ...
        }
    }

// After
    func start() async {
        await refreshCompleteState()
        await EventRouter.shared.register(self)

        // WorkspaceObserver setup on main thread
        await MainActor.run {
            let workspace = WorkspaceObserver()
            workspace.observe()
            self.workspaceObserver = workspace
        }

        observeExistingApplications()
        startPolling(interval: 3.0)
    }
```

---

## Task 12: Remove updateWindowSync Helper

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift` (lines ~657-668)

**Step 1: Delete the helper function**

```swift
// Delete entirely
    private func updateWindowSync(
        _ windowID: UInt32,
        mutation: (inout WindowState) -> Void
    ) {
        // ...
    }
```

**Step 2: Replace usages with direct mutation**

In `handleWindowTitleChanged`:
```swift
    private func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        let key = String(windowID)
        guard var window = state.windows[key] else { return }
        window.title = title
        window.lastUpdated = Date()
        state.windows[key] = window
        state.metadata.update()
    }
```

---

## Task 13: Update WindowManipulator

**Files:**
- Modify: `grid-server/Sources/GridServer/WindowManipulator.swift`

**Step 1: Update ManipulationContext.from() to be async (line ~29)**

```swift
// Before
    static func from(windowID: UInt32) -> ManipulationContext? {
        let state = StateManager.shared.getState()
        // ...
    }

// After
    static func from(windowID: UInt32) async -> ManipulationContext? {
        let state = await StateManager.shared.getState()
        guard let windowState = state.windows[String(windowID)] else {
            return nil
        }
        return ManipulationContext(
            windowID: windowID,
            pid: windowState.pid,
            frame: windowState.frame
        )
    }
```

**Step 2: Remove stateManager computed property (line ~20)**

```swift
// Delete this line
    var stateManager: StateManager { StateManager.shared }
```

**Step 3: Make context-based methods async and call StateManager directly**

```swift
// Before (line ~137)
    func moveWindow(context: ManipulationContext, to point: CGPoint) -> Bool {
        // ...
        context.stateManager.setWindowFrame(context.windowID, frame: newFrame)
        return result
    }

// After
    func moveWindow(context: ManipulationContext, to point: CGPoint) async -> Bool {
        guard let element = getAXElement(pid: context.pid, windowID: context.windowID) else {
            return false
        }
        let result = setWindowPosition(element: element, point: point)
        if result {
            let currentSize = context.frame?.size ?? CGSize(width: 100, height: 100)
            let newFrame = CGRect(origin: point, size: currentSize)
            await StateManager.shared.setWindowFrame(context.windowID, frame: newFrame)
        }
        return result
    }
```

**Step 4: Apply same pattern to other context methods**

- `resizeWindow(context:to:)` (line ~151)
- `setWindowFrame(context:frame:)` (line ~165)
- `minimizeWindow(context:)` (line ~177)
- `unminimizeWindow(context:)` (line ~186)
- `focusWindow(context:)` (line ~453)

**Step 5: Update moveWindowToDisplay (line ~464)**

```swift
// Before
    func moveWindowToDisplay(windowID: UInt32, displayUUID: String, position: CGPoint?, stateManager: StateManager) -> Bool {
        guard let targetSpace = stateManager.getState().spaces.values.first(...) else { ... }
        // ...
    }

// After
    func moveWindowToDisplay(windowID: UInt32, displayUUID: String, position: CGPoint?) async -> Bool {
        let state = await StateManager.shared.getState()
        guard let targetSpace = state.spaces.values.first(where: { $0.displayUUID == displayUUID }) else {
            Task { JSONLogger.shared.log("err.display", data: ["reason": "no_space", "uuid": displayUUID]) }
            return false
        }
        // ...
        await StateManager.shared.updateWindowSpacesPublic(windowID)
        return true
    }
```

---

## Task 14: Update MouseHandler

**Files:**
- Modify: `grid-server/Sources/GridServer/MouseHandler.swift` (line ~199)

**Problem:** `handleMouseDown` is a sync CGEvent callback that calls `getState()`.

**Solution:** Cache state or fetch asynchronously before event handling.

```swift
// Option 1: Pre-fetch state periodically (simpler)
private var cachedState: WindowManagerState?

func updateCachedState() {
    Task {
        cachedState = await StateManager.shared.getState()
    }
}

private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
    let point = event.location

    // Use cached state (may be slightly stale, acceptable for edge detection)
    guard let state = cachedState else {
        return Unmanaged.passRetained(event)
    }

    if let hit = edgeDetector.detectEdge(point: point, state: state) {
        // ...
    }
    // ...
}
```

Call `updateCachedState()` periodically or after state changes.

---

## Task 15: Update main.swift

**Files:**
- Modify: `grid-server/Sources/GridServer/main.swift` (lines ~99, 107)

**Step 1: Wrap StateManager initialization in Task**

```swift
// Before (line ~99)
            StateManager.shared.start()
            jlog("state.init")

            // ... border setup ...
            StateManager.shared.borderEvents = borderEvents

// After
            // Initialize StateManager (async)
            Task {
                await StateManager.shared.start()
                jlog("state.init")
            }

            // ... border setup ...

            // Set borderEvents on actor
            Task {
                await StateManager.shared.setBorderEvents(borderEvents)
            }
```

**Step 2: Add setter method to StateManager for borderEvents**

In `StateManager.swift`, add:
```swift
    func setBorderEvents(_ events: BorderEvents) {
        self.borderEvents = events
    }
```

---

## Task 16: Remove Dead Observer Properties

**Files:**
- Modify: `grid-server/Sources/GridServer/ApplicationObserver.swift`
- Modify: `grid-server/Sources/GridServer/WorkspaceObserver.swift`

**Step 1: Remove from ApplicationObserver (line ~17)**

```swift
// Delete
    weak var stateManager: StateManager?
```

**Step 2: Update observe() signature (line ~36)**

```swift
// Before
    func observe(stateManager: StateManager) -> Bool {
        self.stateManager = stateManager
        // ...
    }

// After
    func observe() -> Bool {
        // ... (remove stateManager assignment)
    }
```

**Step 3: Same for WorkspaceObserver (lines ~18, 23)**

```swift
// Delete property
    weak var stateManager: StateManager?

// Update method
    func observe() {
        // ... (remove stateManager parameter and assignment)
    }
```

**Step 4: Update StateManager to call without parameter**

In `StateManager.start()`:
```swift
// Before
    workspace.observe(stateManager: self)

// After
    workspace.observe()
```

---

## Task 17: Update MessageHandler

**Files:**
- Modify: `grid-server/Sources/GridServer/MessageHandler.swift`

**Pattern: Wrap all handlers that use StateManager in Task {}**

```swift
// Before (line ~133)
        register(method: "dump") { [weak self] request, completion in
            do {
                var state = try StateManager.shared.getStateDictionary()
                // ...
            }
        }

// After
        register(method: "dump") { [weak self] request, completion in
            Task {
                do {
                    var state = try await StateManager.shared.getStateDictionary()
                    state.serverVersion = GridServerVersion
                    state.serverCommit = GridServerCommit

                    let response = Response(id: request.id, result: AnyCodable(state))
                    completion(response)
                } catch {
                    JSONLogger.shared.log("err.state", data: ["op": "dump", "error": "\(error)"])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32603, message: "Internal error")))
                }
            }
        }
```

**Apply Task wrapper to all handlers using StateManager.shared:**
- `dump` (line ~133)
- `updateWindow` (line ~210)
- `window.setOpacity` (line ~356)
- `window.fadeOpacity` (line ~382)
- `window.getOpacity` (line ~406)
- `window.setLayer` (line ~438)
- `window.getLayer` (line ~462)
- `window.setSticky` (line ~490)
- `window.isSticky` (line ~514)
- `window.minimize` (line ~553)
- `window.unminimize` (line ~584)
- `window.isMinimized` (line ~609)
- `window.focus` (line ~666)
- `space.create` (line ~702)
- `space.destroy` (line ~726)
- `space.focus` (line ~750)
- `mouse.warp` (line ~785)

**Also update handlers that use async WindowManipulator methods**

---

## Task 18: Build and Fix Remaining Errors

**Files:** Various

**Step 1: Build**

```bash
cd /Users/r/repos/theGrid/.worktrees/the-great-refactor && swift build 2>&1
```

**Step 2: Common fixes needed**

- Add `await` before actor method calls
- Add `async` to method signatures calling async methods
- Wrap sync callbacks in `Task { }`
- Use `nonisolated` for methods that don't access actor state

**Step 3: Iterate until build succeeds**

---

## Task 19: Test Basic Functionality

**Step 1: Start server**

```bash
make run
```

**Step 2: Test ping**

```bash
./grid-cli/bin/thegrid ping
```

**Step 3: Test dump**

```bash
./grid-cli/bin/thegrid dump | head -20
```

**Step 4: Test focus (verify race condition is fixed)**

```bash
# Get a window ID
WID=$(./grid-cli/bin/thegrid dump | jq -r '.windows | keys[0]')

# Focus and immediately dump - should show correct focusedWindow
./grid-cli/bin/thegrid focus $WID && ./grid-cli/bin/thegrid dump | jq '.metadata.focusedWindowID'
```

Expected: Window ID matches, not null.

---

## Task 20: Commit

```bash
git add -A && git commit -m "$(cat <<'EOF'
refactor(server): convert StateManager from class to actor

BREAKING: StateManager public methods are now async

- Fixes critical race condition where focusedWindowID could be null
  after focus events (executeOnQueue spawned Tasks outside queue)
- Removes DispatchQueue and all queue helpers
- All public methods now async: getState, setFocusedWindow, etc.
- MessageHandler handlers wrapped in Task {} for async access
- WindowManipulator context methods now async
- Removed dead stateManager properties from observers
- Fixed polling timer to use global queue with Task wrapper
- Added reentrancy protection in focus handling

The bug: queue.async spawned a Task that ran on Swift's cooperative
thread pool. queue.sync reads completed before the Task finished.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Risk Analysis

| Risk | Severity | Mitigation |
|------|----------|------------|
| Singleton init race | Critical | Fixed: Use `static let _shared` with computed `shared` |
| WindowManipulator breaks | Critical | Fixed: Added Task 13 for full update |
| Polling timer crash | Critical | Fixed: Task 4 updates to global queue |
| Actor reentrancy | High | Fixed: Task 9 makes focus updates synchronous |
| MouseHandler sync context | High | Fixed: Task 14 adds state caching |
| Build broken for extended time | Medium | Tasks ordered to minimize breakage |

## Rollback Strategy

```bash
git checkout feature/the-great-refactor-backup
```

---

## Success Criteria

- [ ] StateManager is a Swift Actor
- [ ] No DispatchQueue or queue helpers remain
- [ ] Build succeeds with no errors
- [ ] `thegrid ping` returns successfully
- [ ] `thegrid dump` returns valid state
- [ ] Focus + immediate dump shows correct focusedWindowID (race fixed)
- [ ] Borders correctly track focused window
- [ ] No crashes during rapid window operations

---

## Quick Reference - Migration Patterns

### Pattern 1: Singleton
```swift
// Before
class Foo { static let shared = Foo() }

// After
actor Foo {
    private static let _shared = Foo()
    static var shared: Foo { _shared }
}
```

### Pattern 2: Sync Callback → Async Actor
```swift
// Before
register("method") { req, done in
    let state = StateManager.shared.getState()
    done(Response(result: state))
}

// After
register("method") { req, done in
    Task {
        let state = await StateManager.shared.getState()
        done(Response(result: state))
    }
}
```

### Pattern 3: Context Method → Async
```swift
// Before
func doThing(context: Context) -> Bool {
    context.stateManager.setFoo(x)
    return true
}

// After
func doThing(context: Context) async -> Bool {
    await StateManager.shared.setFoo(x)
    return true
}
```
