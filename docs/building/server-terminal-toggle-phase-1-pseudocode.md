# Pseudocode: Phase 1 - Server-side terminal toggle

## Files to Modify
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift`

## Design Decision

All terminal logic lives as private methods on GridCommandRouter. A separate class would add injection/setup ceremony for 4 methods and one cached property that have no other callers. The router already handles all domains inline.

## Pseudocode

### GridCommandRouter.swift

#### New property (add to class properties section)

```
// Cached terminal window ID to avoid full-scan on every toggle
private var cachedTerminalWindowID: UInt32? = nil
```

#### Replace `case "terminal"` in dispatch (line 174-176)

```
case "terminal":
    return await handleTerminal()
```

#### handleTerminal() -> CommandResult

```
private func handleTerminal() async -> CommandResult
    // Get fresh window manager state
    let wmState = await stateManager.getState()

    // Try to find existing terminal window
    if let windowID = findTerminalWindow(wmState)
        return await toggleTerminalWindow(windowID, wmState)
    else
        return await launchTerminal()
```

#### findTerminalWindow(_ wmState) -> UInt32?

```
private func findTerminalWindow(_ wmState: WindowManagerState) -> UInt32?
    // Fast path: check cached ID against current state
    if let cached = cachedTerminalWindowID
        if let win = wmState.windows[String(cached)]
            // Verify it's still the terminal (title + bundleID)
            let app = wmState.applications[String(win.pid)]
            if win.title == "grid-terminal"
               && app?.bundleIdentifier == "com.mitchellh.ghostty"
                return cached

        // Cache miss: window gone or identity changed
        cachedTerminalWindowID = nil

    // Slow path: scan all windows
    for (widStr, win) in wmState.windows
        if win.title == "grid-terminal"
            let app = wmState.applications[String(win.pid)]
            if app?.bundleIdentifier == "com.mitchellh.ghostty"
                let wid = UInt32(widStr)
                cachedTerminalWindowID = wid
                return wid

    return nil
```

#### toggleTerminalWindow(_ windowID, _ wmState) -> CommandResult

```
private func toggleTerminalWindow(
    _ windowID: UInt32,
    _ wmState: WindowManagerState
) async -> CommandResult
    let cid = wmState.metadata.connectionID

    // Check if window is currently visible (ordered in)
    var orderedIn: UInt8 = 0
    let err = SLSWindowIsOrderedIn(cid, windowID, &orderedIn)
    let isVisible = (err == .success && orderedIn != 0)

    // Determine if window is on the active space
    let activeSpaceID = wmState.metadata.activeSpaceID
    let win = wmState.windows[String(windowID)]
    let onActiveSpace: Bool
    if let activeSpaceID, let win
        onActiveSpace = win.spaces.contains(activeSpaceID)
    else
        onActiveSpace = false

    if isVisible && onActiveSpace
        // Terminal is visible on this space -> hide it
        _ = windowManipulator.mssClient.orderWindowOut(windowID)
        jlog("term.hide", data: ["wid": windowID])
        return .ok("terminal hidden")
    else
        // Terminal is hidden or on another space -> bring here and show
        if let activeSpaceID
            // Move to active space if not already there
            if !onActiveSpace
                _ = windowManipulator.mssClient.moveWindowToSpace(
                    windowID: windowID, spaceID: activeSpaceID
                )

        // Show and focus
        _ = windowManipulator.mssClient.orderWindowToFront(windowID)
        if let pid = win?.pid
            _ = windowManipulator.focusWindow(pid: pid, windowID: windowID)

        jlog("term.show", data: ["wid": windowID])
        return .ok("terminal shown")
```

#### launchTerminal() -> CommandResult

```
private func launchTerminal() async -> CommandResult
    // Build the launch command
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [
        "-na", "Ghostty.app",
        "--args",
        "--title=grid-terminal",
        "--window-decoration=none",
        "-e", "tmux", "new-session", "-A", "-s", "grid-scratch"
    ]

    do
        try process.run()
    catch
        jlog("err.term.launch", data: ["err": error.localizedDescription])
        return .error("failed to launch terminal: \(error.localizedDescription)")

    // Poll for the terminal window to appear (up to 3 seconds)
    let maxAttempts = 15
    for attempt in 0..<maxAttempts
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        let wmState = await stateManager.getState()
        if let windowID = findTerminalWindow(wmState)
            // Set layer to above (persists across hide/show)
            _ = windowManipulator.mssClient.setWindowLayer(
                windowID: windowID, layer: .above
            )

            // Focus the window
            if let win = wmState.windows[String(windowID)]
                _ = windowManipulator.focusWindow(
                    pid: win.pid, windowID: windowID
                )

            jlog("term.launched", data: [
                "wid": windowID,
                "attempts": attempt + 1
            ])
            return .ok("terminal launched")

    jlog("err.term.timeout")
    return .error("terminal launch timed out")
```

## Design Notes

1. **Cache invalidation**: The cache is checked against live state every call. If the cached window ID no longer maps to a Ghostty window with title "grid-terminal", the cache is cleared and a full scan runs. This handles Ghostty restarts gracefully.

2. **"Follow me" semantics**: The terminal is moved to the active space when shown, not made sticky. This means it only appears where you invoke it, not on all spaces.

3. **Layer persistence**: `setWindowLayer(.above)` is only called on first launch. The layer persists across `orderWindowOut`/`orderWindowToFront` cycles, so subsequent toggles do not need to re-set it.

4. **No frame management**: Ghostty manages its own window size via its config. The toggle only controls visibility, space membership, and focus.

5. **Information hiding**: Callers of `dispatch("@terminal")` get a simple ok/error. All window finding, visibility checking, space movement, and process launching are hidden behind `handleTerminal()`.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (single-class approach chosen over separate module)
- [x] Ready for implementation
