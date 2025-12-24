# Fix executeOnQueueSync Race Condition Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the `executeOnQueueSync` method that incorrectly uses `queue.async` instead of `queue.sync`, causing race conditions in high-frequency state mutations.

**Architecture:** Fix `executeOnQueueSync` to use proper synchronization with re-entrancy protection to prevent deadlocks when called from within the queue.

**Tech Stack:** Swift, GCD (Grand Central Dispatch), DispatchQueue

---

## Background

The `executeOnQueueSync` method at `StateManager.swift:560-564` is named "Sync" but uses `queue.async`:

```swift
private func executeOnQueueSync(_ operation: @escaping () -> Void) {
    queue.async {  // BUG: Should be sync!
        operation()
    }
}
```

This causes race conditions when `handleWindowMoved`, `handleWindowResized`, `setFocusedWindow`, `setWindowFrame`, and `setWindowMinimized` are called rapidly, as operations overlap instead of serializing.

**Evidence:** Server crashed 7 times in 5 minutes with no graceful shutdown, indicating race condition crashes (EXC_BAD_ACCESS on dictionary access). No additional instrumentation needed - crash evidence is sufficient.

---

### Task 1: Add Queue Key for Re-entrancy Detection

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:25-26` (property declaration)
- Modify: `grid-server/Sources/GridServer/StateManager.swift:44-45` (init body)

**Step 1: Add queue-specific key property**

After line 25 (the queue declaration), add:

```swift
private let queue = DispatchQueue(label: "com.grid.StateManager", qos: .userInitiated)
private let queueKey = DispatchSpecificKey<Bool>()
```

**Step 2: Set the queue-specific value in init**

At line 45 (first line inside `init()` body), add:

```swift
init() {
    queue.setSpecific(key: queueKey, value: true)
    // ... rest of init
```

**Step 3: Build to verify syntax**

Run: `cd /Users/r/repos/theGrid/.worktrees/statemanager-refactor && swift build --package-path grid-server 2>&1 | head -20`
Expected: Build succeeds or shows unrelated warnings

**Step 4: Commit**

```bash
git add grid-server/Sources/GridServer/StateManager.swift
git commit -m "feat(server): add queue key for re-entrancy detection"
```

---

### Task 2: Audit for Potential Deadlock Scenarios

**Files:**
- Read only: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Check if executeOnQueueSync callers call back into it**

Functions using `executeOnQueueSync`:
- `setFocusedWindow` (line 671)
- `setWindowFrame` (line 707)
- `setWindowMinimized` (line 723)
- `handleWindowMoved` (line 1287)
- `handleWindowResized` (line 1304)

**Step 2: Verify helper functions don't call executeOnQueueSync**

Check that these sync helpers (called from within executeOnQueueSync closures) don't call back:

```bash
grep -n "executeOnQueueSync\|executeOnQueue" grid-server/Sources/GridServer/StateManager.swift | grep -v "private func"
```

Expected: Only the call sites listed above, no calls from helper functions like:
- `computeDisplayUUID`
- `deriveSpaceFromDisplay`
- `displayForWindowFrame`

**Step 3: Document findings**

If any helpers call `executeOnQueueSync`, they must be refactored before proceeding.
If clean, proceed to Task 3.

---

### Task 3: Fix executeOnQueueSync with Re-entrancy Protection

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift:558-564`

**Step 1: Replace current implementation with fixed version**

Replace lines 558-564:

```swift
    /// Execute a synchronous operation on the state queue
    /// Use this for high-frequency operations that must be truly serialized
    /// Includes re-entrancy protection to prevent deadlock when called from within queue
    /// WARNING: Closures must not call async functions without wrapping in Task {}
    private func executeOnQueueSync(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            // Already on queue, execute directly to avoid deadlock
            operation()
        } else {
            queue.sync {
                operation()
            }
        }
    }
```

**Step 2: Build to verify syntax**

Run: `cd /Users/r/repos/theGrid/.worktrees/statemanager-refactor && swift build --package-path grid-server 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit fix**

```bash
git add grid-server/Sources/GridServer/StateManager.swift
git commit -m "fix(server): use queue.sync with re-entrancy protection in executeOnQueueSync

The method was incorrectly using queue.async despite the name, causing
race conditions when window move/resize events fired rapidly. This led
to EXC_BAD_ACCESS crashes on dictionary access.

Added re-entrancy detection using DispatchSpecificKey to prevent
deadlock if called from within the queue context."
```

---

### Task 4: Verify Fix with Extended Monitoring

**Files:**
- None (testing only)

**Step 1: Start server fresh**

```bash
cd /Users/r/repos/theGrid/.worktrees/statemanager-refactor && make run
```

**Step 2: Record baseline restart count**

```bash
grep '"ev":"srv.start"' ~/.local/state/thegrid/thegrid-server.json | wc -l
```

Save this number.

**Step 3: Test basic window operations**

```bash
~/.local/bin/thegrid focus left
~/.local/bin/thegrid focus right
~/.local/bin/thegrid dump | jq '.metadata.focusedWindowID'
```
Expected: Focus changes work, dump returns valid state

**Step 4: Stress test with rapid operations**

```bash
for i in {1..20}; do ~/.local/bin/thegrid focus left; ~/.local/bin/thegrid focus right; done
```
Expected: No crashes, operations complete

**Step 5: Extended stability monitoring (5 minutes)**

Wait 5 minutes while interacting with windows normally (move, resize, focus).

This matches the original crash window (7 crashes in 5 minutes).

**Step 6: Verify no crashes occurred**

```bash
grep '"ev":"srv.start"' ~/.local/state/thegrid/thegrid-server.json | wc -l
```
Expected: Same count as baseline (no new restarts)

**Step 7: Check for errors**

```bash
grep -E '"ev":"err\.' ~/.local/state/thegrid/thegrid-server.json | tail -10
```
Expected: No new error events related to state/windows

---

### Task 5: Final Verification and Summary

**Files:**
- None

**Step 1: Verify implementation is clean**

```bash
grep -A 8 "private func executeOnQueueSync" grid-server/Sources/GridServer/StateManager.swift
```

Expected output:
```swift
    private func executeOnQueueSync(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            // Already on queue, execute directly to avoid deadlock
            operation()
        } else {
            queue.sync {
                operation()
            }
        }
    }
```

**Step 2: Verify queue key is set**

```bash
grep -n "queueKey" grid-server/Sources/GridServer/StateManager.swift
```

Expected: 3 matches:
- Line ~26: `private let queueKey = DispatchSpecificKey<Bool>()`
- Line ~45: `queue.setSpecific(key: queueKey, value: true)`
- Line ~561: `if DispatchQueue.getSpecific(key: queueKey) == true`

**Step 3: Summary output**

If all steps passed:
- Race condition fixed
- No crashes in 5-minute window
- Re-entrancy protection in place

---

## Summary

| Task | Description | Risk |
|------|-------------|------|
| 1 | Add queue key for re-entrancy detection | Low |
| 2 | Audit for potential deadlock scenarios | Low |
| 3 | Fix with queue.sync + re-entrancy protection | Medium |
| 4 | Extended stability verification (5 min) | Low |
| 5 | Final verification | Low |

**Total:** 5 tasks

**Rollback:** If deadlock issues arise, revert commits and investigate which code path is causing re-entrancy.

---

## Code Review Notes

This plan was reviewed and updated to address:
- ~~Removed instrumentation task~~ - crash evidence is sufficient confirmation
- Added explicit queue key setup location (line 45, first line of init)
- Added deadlock prevention audit (Task 2)
- Extended monitoring to match original 5-minute crash window
- Added warning comment about async calls in closures
