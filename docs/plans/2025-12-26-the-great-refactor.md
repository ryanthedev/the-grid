# StateManager Actor Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert StateManager from a DispatchQueue-based class to a Swift Actor to fix a critical race condition where `focusedWindowID` can be null even after focus events are processed.

**Architecture:** StateManager becomes an actor with compiler-enforced isolation. All public methods become async. MessageHandler wraps calls in Tasks to bridge sync handlers to async StateManager. EventRouter (already an actor) routes events to the StateManager actor.

**Tech Stack:** Swift 5.9+ Actors, async/await, macOS 14+ Sonoma, Private SkyLight APIs

---

## Part 1: Bug Investigation Findings

### Symptom
Border crashed and stuck showing only red (active style). Server state showed `focusedWindow: null` even though Ghostty was the active app with visible windows.

### Root Cause: Broken Queue Synchronization

**Location:** `grid-server/Sources/GridServer/StateManager.swift:524`

```swift
private func executeOnQueue(_ operation: @escaping () async -> Void) {
    let span = CurrentSpan.current
    queue.async { [span] in
        Task {  // <-- THIS IS THE BUG
            await CurrentSpan.$current.withValue(span) {
                await operation()
            }
        }
    }
}
```

**The Problem:**
1. `queue.async` dispatches work to the serial queue
2. Inside, it spawns an **unstructured Task**
3. The Task runs on Swift's cooperative thread pool, NOT the queue
4. The queue dispatch returns immediately, before the Task completes
5. `getState()` uses `queue.sync` which only waits for queue work, not the Task
6. Result: State reads can return stale data

---

## Part 2: Implementation Plan

### Task 1: Verify Build and Create Backup Branch

**Files:**
- None (git operations only)

**Step 1: Verify the build compiles**

Run: `cd /Users/r/repos/theGrid/.worktrees/the-great-refactor && swift build -c debug 2>&1 | tail -20`
Expected: Build Succeeded or similar

**Step 2: Create a backup branch**

Run: `git checkout -b feature/the-great-refactor-backup && git checkout feature/the-great-refactor`
Expected: Switched to branch 'feature/the-great-refactor'

**Step 3: Commit any uncommitted changes**

Run: `git status`
Expected: Shows current state

---

### Task 2: Convert StateManager Class to Actor

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:16`

**Step 1: Change class to actor declaration**

Change line 16 from:
```swift
class StateManager: StateEventHandler {
```
To:
```swift
actor StateManager: StateEventHandler {
```

**Step 2: Remove singleton pattern (actors can't have static stored properties that reference self)**

Change lines 18-19 from:
```swift
    // MARK: - Singleton

    static let shared = StateManager()
```
To:
```swift
    // MARK: - Shared Instance

    // Note: Using nonisolated(unsafe) for singleton pattern with actor
    // This is safe because: 1) shared is set once at startup, 2) all access is through await
    nonisolated(unsafe) static var shared: StateManager!

    static func initialize() -> StateManager {
        let manager = StateManager()
        shared = manager
        return manager
    }
```

**Step 3: Attempt to build to see errors**

Run: `cd /Users/r/repos/theGrid/.worktrees/the-great-refactor && swift build 2>&1 | head -50`
Expected: Multiple compilation errors (this is expected - we'll fix them next)

---

### Task 3: Remove DispatchQueue Infrastructure

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:25-27, 46, 519-548`

**Step 1: Remove queue property and queueKey**

Delete these lines (around 25-27):
```swift
    private let queue = DispatchQueue(label: "com.grid.StateManager", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
```

**Step 2: Remove queue setup in init**

Delete this line from init (around line 46):
```swift
        queue.setSpecific(key: queueKey, value: true)
```

**Step 3: Remove executeOnQueue helper**

Delete the entire function (around lines 524-533):
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

**Step 4: Remove executeOnQueueSync helper**

Delete the entire function (around lines 539-548):
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

### Task 4: Convert Public State Access Methods to Async

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:82-100`

**Step 1: Convert getState() to async**

Change from:
```swift
    func getState() -> WindowManagerState {
        return queue.sync {
            return state
        }
    }
```
To:
```swift
    func getState() -> WindowManagerState {
        return state
    }
```

**Step 2: Convert getStateJSON() - remove queue.sync**

The method already works with actor isolation:
```swift
    func getStateJSON() throws -> Data {
        let state = getState()  // Now just accesses actor-isolated state
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }
```

**Step 3: Convert getStateDictionary()**

Already works - just calls getState() internally.

---

### Task 5: Convert Event Handlers - Remove executeOnQueue Wrappers

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift` (multiple handlers)

**Step 1: Convert handleWindowCreated (around line 1246)**

Change from:
```swift
    private func handleWindowCreated(_ windowID: UInt32, pid: pid_t) {
        executeOnQueue {
            // Create new window state
            var window = WindowState(id: windowID)
            // ... rest of implementation
        }
    }
```
To:
```swift
    private func handleWindowCreated(_ windowID: UInt32, pid: pid_t) async {
        // Create new window state
        var window = WindowState(id: windowID)
        // ... rest of implementation (remove self. where not needed)
    }
```

**Step 2: Convert handleWindowDestroyed (around line 1317)**

Change from:
```swift
    private func handleWindowDestroyed(_ windowID: UInt32) {
        executeOnQueue {
            // implementation
        }
    }
```
To:
```swift
    private func handleWindowDestroyed(_ windowID: UInt32) async {
        // implementation (remove self. prefix, remove executeOnQueue wrapper)
    }
```

**Step 3: Convert handleWindowFocused (around line 1389)**

Change from:
```swift
    private func handleWindowFocused(_ windowID: UInt32) {
        executeOnQueue {
            let stateSpan = await CurrentSpan.current?.startChild("state", data: ["wid": Int(windowID)])
            // ...
        }
    }
```
To:
```swift
    private func handleWindowFocused(_ windowID: UInt32) async {
        let stateSpan = await CurrentSpan.current?.startChild("state", data: ["wid": Int(windowID)])
        // ...
    }
```

**Step 4: Convert remaining handlers using executeOnQueue**

Apply same pattern to:
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

### Task 6: Convert Event Handlers - Remove executeOnQueueSync Wrappers

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Convert handleWindowMoved (around line 1355)**

Change from:
```swift
    private func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        executeOnQueueSync {
            guard var window = self.state.windows[String(windowID)] else { return }
            // ...
        }
    }
```
To:
```swift
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

**Step 2: Convert handleWindowResized (around line 1372)**

Same pattern as handleWindowMoved.

**Step 3: Convert handleWindowTitleChanged (around line 1442)**

Change from:
```swift
    private func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        executeOnQueueSync {
            self.updateWindowSync(windowID) { $0.title = title }
        }
    }
```
To:
```swift
    private func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        updateWindowSync(windowID) { $0.title = title }
    }
```

---

### Task 7: Convert Public Mutation Methods

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:680-759`

**Step 1: Convert setFocusedWindow (around line 680)**

Change from:
```swift
    func setFocusedWindow(_ windowID: UInt32) {
        var activeSpaceID: UInt64 = 0
        var activeDisplayUUID: String = ""

        executeOnQueueSync {
            self.state.metadata.focusedWindowID = windowID
            // ... rest of sync implementation
        }

        // Emit focusChanged event (async)
        Task {
            // ...
        }
    }
```
To:
```swift
    func setFocusedWindow(_ windowID: UInt32) async {
        state.metadata.focusedWindowID = windowID

        // Update active display (geometric lookup)
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

**Step 2: Convert setWindowFrame (around line 733)**

Change from:
```swift
    func setWindowFrame(_ windowID: UInt32, frame: CGRect) {
        executeOnQueueSync {
            // ...
        }
    }
```
To:
```swift
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

**Step 3: Convert setWindowMinimized (around line 749)**

Change from:
```swift
    func setWindowMinimized(_ windowID: UInt32, minimized: Bool) {
        executeOnQueueSync {
            // ...
        }
    }
```
To:
```swift
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

### Task 8: Update handle() Method Calls

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:105-198`

**Step 1: Update handle() to call async handlers**

The `handle(_ event: StateEvent, context: EventContext)` method needs to await the handlers.

Change calls from:
```swift
        case .windowCreated(let windowID, let pid):
            handleWindowCreated(windowID, pid: pid)
```
To:
```swift
        case .windowCreated(let windowID, let pid):
            await handleWindowCreated(windowID, pid: pid)
```

Apply to all handler calls in the switch statement that now require await.

---

### Task 9: Convert start() Method

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:59-80`

**Step 1: Convert start() to async**

Change from:
```swift
    func start() {
        executeOnQueue {
            await self.refreshCompleteState()
            await EventRouter.shared.register(self)
            // ...
        }
    }
```
To:
```swift
    func start() async {
        // Build initial state
        await refreshCompleteState()

        // Register with EventRouter
        await EventRouter.shared.register(self)

        // Set up workspace observer (must be on main thread)
        await MainActor.run {
            let workspace = WorkspaceObserver()
            workspace.observe(stateManager: self)
            self.workspaceObserver = workspace
        }

        // Create AX observers for existing applications
        observeExistingApplications()

        // Start periodic polling
        startPolling(interval: 3.0)
    }
```

---

### Task 10: Update MessageHandler to Use Async StateManager

**Files:**
- Modify: `grid-server/Sources/GridServer/MessageHandler.swift`

**Step 1: Update dump handler (around line 130)**

Change from:
```swift
        register(method: "dump") { [weak self] request, completion in
            do {
                var state = try StateManager.shared.getStateDictionary()
                // ...
            } catch {
                // ...
            }
        }
```
To:
```swift
        register(method: "dump") { [weak self] request, completion in
            Task {
                do {
                    var state = try await StateManager.shared.getStateDictionary()
                    state.serverVersion = GridServerVersion
                    state.serverCommit = GridServerCommit

                    let response = Response(
                        id: request.id,
                        result: AnyCodable(state)
                    )
                    completion(response)
                } catch {
                    JSONLogger.shared.log("err.state", data: ["op": "dump", "error": "\(error)"])
                    let response = Response(
                        id: request.id,
                        error: ErrorInfo(
                            code: -32603,
                            message: "Internal error: \(error.localizedDescription)"
                        )
                    )
                    completion(response)
                }
            }
        }
```

**Step 2: Update updateWindow handler (around line 160)**

Wrap in Task and use await for StateManager.shared.getState():
```swift
        register(method: "updateWindow") { [weak self] request, completion in
            Task {
                // ... existing parameter extraction ...

                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                // ... rest of handler ...
            }
        }
```

**Step 3: Update all other handlers that call StateManager.shared.getState()**

Apply the same Task wrapper pattern to:
- `window.setOpacity` (line ~342)
- `window.fadeOpacity` (line ~367)
- `window.getOpacity` (line ~393)
- `window.setLayer` (line ~419)
- `window.getLayer` (line ~449)
- `window.setSticky` (line ~476)
- `window.isSticky` (line ~501)
- `window.minimize` (line ~525)
- `window.unminimize` (line ~565)
- `window.isMinimized` (line ~596)
- `window.focus` (line ~622)
- `space.create` (line ~689)
- `space.destroy` (line ~713)
- `space.focus` (line ~737)
- `mouse.warp` (line ~763)

---

### Task 11: Update ApplicationObserver

**Files:**
- Modify: `grid-server/Sources/GridServer/ApplicationObserver.swift:17, 36`

**Step 1: Keep weak reference (actors can have weak references)**

The `weak var stateManager: StateManager?` on line 17 stays the same.

**Step 2: Update observe() method signature if needed**

The observe() method passes `self` to the observer. Since StateManager is now an actor, we need to ensure the reference is passed correctly:

```swift
    func observe(stateManager: StateManager) -> Bool {
        self.stateManager = stateManager
        // ... rest unchanged
    }
```

This should work without changes since we're just storing a reference.

---

### Task 12: Update WorkspaceObserver

**Files:**
- Modify: `grid-server/Sources/GridServer/WorkspaceObserver.swift:18, 23`

**Step 1: Keep weak reference**

The `weak var stateManager: StateManager?` on line 18 stays the same.

**Step 2: Update observe() method**

```swift
    func observe(stateManager: StateManager) {
        self.stateManager = stateManager
        // ... rest unchanged
    }
```

No changes needed - just stores the reference.

---

### Task 13: Update Server Initialization

**Files:**
- Modify: `grid-server/Sources/GridServer/main.swift` or wherever server starts

**Step 1: Find server startup code**

Run: `grep -r "StateManager.shared" grid-server/Sources/`
Expected: Shows all usages

**Step 2: Update initialization to use async**

Change from:
```swift
StateManager.shared.start()
```
To:
```swift
Task {
    let stateManager = StateManager.initialize()
    await stateManager.start()
}
```

Or wrap in a Task at the appropriate startup point.

---

### Task 14: Remove updateWindowSync Helper

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:657-668`

**Step 1: Remove updateWindowSync**

Delete the function since actor isolation makes it unnecessary:
```swift
    private func updateWindowSync(
        _ windowID: UInt32,
        mutation: (inout WindowState) -> Void
    ) {
        // ... delete entire function
    }
```

**Step 2: Replace usages with direct mutation**

In handleWindowTitleChanged, change:
```swift
    private func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        updateWindowSync(windowID) { $0.title = title }
    }
```
To:
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

### Task 15: Build and Fix Remaining Errors

**Files:**
- Various

**Step 1: Build the project**

Run: `cd /Users/r/repos/theGrid/.worktrees/the-great-refactor && swift build 2>&1`
Expected: May have remaining errors

**Step 2: Fix any remaining compilation errors**

Common fixes:
- Add `await` before actor method calls
- Add `async` to method signatures that call async methods
- Wrap synchronous callback handlers in `Task { }`
- Use `nonisolated` for methods that don't need actor isolation

**Step 3: Iterate until build succeeds**

Run: `swift build`
Expected: Build Succeeded

---

### Task 16: Test Basic Functionality

**Files:**
- None

**Step 1: Start the server**

Run: `make run` (or however server is started)
Expected: Server starts without crash

**Step 2: Test ping**

Run: `./grid-cli/bin/thegrid ping`
Expected: Pong response

**Step 3: Test dump**

Run: `./grid-cli/bin/thegrid dump | head -20`
Expected: JSON state output with windows, displays, etc.

**Step 4: Test focus**

Run: `./grid-cli/bin/thegrid focus <window-id>`
Expected: Focus changes, state reflects new focus

---

### Task 17: Commit the Refactor

**Files:**
- All modified files

**Step 1: Review changes**

Run: `git diff --stat`
Expected: Shows modified files

**Step 2: Commit**

Run:
```bash
git add -A && git commit -m "$(cat <<'EOF'
refactor(server): convert StateManager from class to actor

BREAKING: StateManager is now a Swift Actor

- Fixes critical race condition where focusedWindowID could be null
  after focus events due to executeOnQueue spawning unstructured Tasks
- Removes DispatchQueue and all queue helpers (executeOnQueue,
  executeOnQueueSync)
- All public methods are now async (getState, setFocusedWindow, etc.)
- MessageHandler handlers wrapped in Task {} for async StateManager access
- Compiler-enforced thread safety via actor isolation

The bug manifested as:
- CLI: "Focused window: 37860"
- Immediate dump: "focusedWindow: null"

Root cause: queue.async spawned a Task that ran on Swift's cooperative
thread pool, not the queue. queue.sync reads completed before the Task.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```
Expected: Commit created

---

## Part 3: Risk Analysis

### High Risk Areas

1. **Singleton Pattern Change**
   - Risk: Breaking existing `StateManager.shared` usages
   - Mitigation: Use `nonisolated(unsafe) static var` with explicit initialization

2. **Synchronous to Async Conversion**
   - Risk: Deadlocks if async calls made from wrong context
   - Mitigation: Wrap handler callbacks in `Task {}`, not `Task.detached`

3. **Actor Reentrancy**
   - Risk: State changes during await points
   - Mitigation: Copy values before await, check state after await

4. **MainActor Requirements**
   - Risk: UI operations on wrong thread
   - Mitigation: Use `await MainActor.run {}` for NSWorkspace setup

### Rollback Strategy

If issues arise:
1. `git checkout feature/the-great-refactor-backup`
2. Cherry-pick any fixes made during refactor
3. Consider incremental approach (fix executeOnQueue first)

---

## Part 4: Success Criteria

The refactor is complete when:

1. [ ] StateManager is a Swift Actor
2. [ ] No DispatchQueue or queue helpers remain
3. [ ] Build succeeds with no warnings
4. [ ] `thegrid ping` returns successfully
5. [ ] `thegrid dump` returns valid state
6. [ ] Focus state is never stale after focus commands
7. [ ] Borders correctly track focused window
8. [ ] No race conditions under rapid window create/destroy

---

## Part 5: Quick Reference - Migration Patterns

### Pattern 1: executeOnQueue Removal

Before:
```swift
func doSomething() {
    executeOnQueue {
        await self.state.foo = bar
    }
}
```

After:
```swift
func doSomething() async {
    state.foo = bar
}
```

### Pattern 2: executeOnQueueSync Removal

Before:
```swift
func doSomething() {
    executeOnQueueSync {
        self.state.foo = bar
    }
}
```

After:
```swift
func doSomething() {
    state.foo = bar
}
```

### Pattern 3: Sync Callback to Async Actor

Before:
```swift
register(method: "foo") { request, completion in
    let state = StateManager.shared.getState()
    completion(Response(id: request.id, result: state))
}
```

After:
```swift
register(method: "foo") { request, completion in
    Task {
        let state = await StateManager.shared.getState()
        completion(Response(id: request.id, result: state))
    }
}
```

### Pattern 4: Singleton with Actor

Before:
```swift
class StateManager {
    static let shared = StateManager()
}
```

After:
```swift
actor StateManager {
    nonisolated(unsafe) static var shared: StateManager!

    static func initialize() -> StateManager {
        let manager = StateManager()
        shared = manager
        return manager
    }
}
```
