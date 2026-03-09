# Pseudocode: Phase 1 - GridTerminalManager Actor + Frame Persistence

## Design: GridTerminalManager

### Approaches Considered
1. **Single actor with all state and logic** - Actor holds saved WID/PID, per-display frames, toggling guard. Constructor-injected dependencies. One public method: `toggle()`. All hide/show/launch/resolve logic is private.
2. **Actor + separate FrameStore value type** - Actor delegates frame persistence to a separate `TerminalFrameStore` struct that handles load/save/lookup. Actor owns the struct and handles toggle logic.
3. **Plain class with lock** - Use a class with `NSLock` or `os_unfair_lock` for thread safety instead of an actor, matching the pattern of GridReconciler.

### Comparison
| Criterion | A (Single actor) | B (Actor + FrameStore) | C (Plain class) |
|-----------|---|---|---|
| Interface simplicity | One method: toggle() | One method: toggle() | One method: toggle() |
| Information hiding | All state private in actor | Frame logic split across two types | All state private with lock |
| Caller ease of use | Simple await | Simple await | Simple await |
| Concurrency safety | Built-in actor isolation | Built-in + struct value semantics | Manual lock management |
| Code complexity | Moderate (single file, ~250 lines) | Higher (two types, coordination) | Higher (manual synchronization) |
| Codebase consistency | Matches GridRecorder pattern | No precedent for extracted value stores | Matches GridReconciler but less safe |

### Choice: A (Single actor)
Rationale: The frame persistence logic is small (3-4 methods, one dictionary). Extracting it adds a type boundary without meaningful information hiding benefit. The actor pattern matches GridRecorder exactly and provides automatic concurrency safety. The toggling guard works naturally with actor serialization.

### Depth Check
- Interface methods: 1 (toggle)
- Hidden details: WID/PID tracking, 4-tier resolution, frame persistence, Ghostty launch, reconciler suppression, hide/show mechanics
- Common case complexity: Simple -- caller says `await terminalManager.toggle()` and everything happens

## Files to Create/Modify
- `grid-server/Sources/GridServer/Grid/GridTerminalManager.swift` (NEW)

## Pseudocode

### GridTerminalManager.swift

```
import Foundation, CoreGraphics, AppKit

CONSTANTS:
  ghosttyBundleID = "com.mitchellh.ghostty"
  ghosttyTitle = "grid:scratch"
  offScreenPoint = CGPoint(-10000, -10000)
  framePersistencePath = XDG.stateHome + "/thegrid/terminal-frames.json"
  pollInterval = 100ms
  pollMaxAttempts = 50
  defaultWidthRatio = 0.80
  defaultHeightRatio = 0.60

actor GridTerminalManager:

  // Dependencies (constructor-injected, let)
  windowManipulator: WindowManipulator
  stateManager: StateManager
  gridReconciler: GridReconciler

  // Mutable state
  savedWindowID: UInt32? = nil
  savedPID: pid_t? = nil
  isHidden: Bool = false
  toggling: Bool = false
  displayFrames: Dictionary<String, CGRect> = empty

  // MARK: - Initialization

  init(windowManipulator, stateManager, gridReconciler):
    store dependencies
    load saved frames from disk

  // MARK: - Public API (single method)

  func toggle() async -> CommandResult:
    // Guard against re-entrant toggle
    if toggling:
      log "term.toggle.skip" (already toggling)
      return .ok("toggle in progress")

    toggling = true
    defer: toggling = false

    // Suppress reconciler for entire toggle operation
    gridReconciler.setSuppressed(true, syncOnResume: false)
    defer: gridReconciler.setSuppressed(false, syncOnResume: true)

    // Tier 1: Saved PID alive + saved WID valid
    if let pid = savedPID, let wid = savedWindowID:
      if isPIDAlive(pid):
        if windowExistsInState(wid):
          if isHidden:
            await show(wid, pid)
          else:
            await hide(wid, pid)
          return .ok(isHidden ? "hidden" : "shown")

    // Tier 2: PID alive, WID stale -- re-query StateManager
    if let pid = savedPID, isPIDAlive(pid):
      if let wid = await findGhosttyWindow(byPID: pid):
        savedWindowID = wid
        // Found the window, it's visible (we didn't hide it), so hide it
        await hide(wid, pid)
        return .ok("hidden")

    // Tier 3: No saved state -- search for orphaned Ghostty window
    if let (wid, pid) = await findAnyGhosttyWindow():
      savedWindowID = wid
      savedPID = pid
      // Found orphaned window, hide it (treat as "currently shown")
      await hide(wid, pid)
      return .ok("hidden")

    // Tier 4: No Ghostty window exists -- launch one
    let result = await launchGhostty()
    return result

  // MARK: - Hide / Show

  private func hide(wid: UInt32, pid: pid_t) async:
    log "term.hide" with wid

    // Save current frame keyed by display UUID before hiding
    let currentFrame = await getCurrentFrame(wid)
    let displayUUID = await getDisplayUUID(forWindow: wid)
    if let frame = currentFrame, let uuid = displayUUID:
      saveFrame(displayUUID: uuid, frame: frame)

    // Set opacity to 0 (cross-process via MSS)
    windowManipulator.mssClient.setWindowOpacity(windowID: wid, opacity: 0.0)

    // Move off-screen via AX API
    if let element = windowManipulator.getAXElement(pid: pid, windowID: wid):
      windowManipulator.setWindowPosition(element: element, point: offScreenPoint)

    isHidden = true

  private func show(wid: UInt32, pid: pid_t) async:
    log "term.show" with wid

    // Determine target frame
    let displayUUID = await getActiveDisplayUUID()
    let targetFrame: CGRect
    if let uuid = displayUUID, let savedFrame = restoreFrame(displayUUID: uuid):
      targetFrame = savedFrame
    else:
      targetFrame = await computeDefaultFrame(displayUUID: displayUUID)

    // Move to target position via AX API
    if let element = windowManipulator.getAXElement(pid: pid, windowID: wid):
      windowManipulator.setWindowFrame(element: element, frame: targetFrame)

    // Set opacity to 1.0 (cross-process via MSS)
    windowManipulator.mssClient.setWindowOpacity(windowID: wid, opacity: 1.0)

    // Bring to front and focus
    windowManipulator.mssClient.orderWindowToFront(wid)
    windowManipulator.focusWindow(pid: pid, windowID: wid)

    isHidden = false

  // MARK: - Window Resolution

  private func isPIDAlive(pid: pid_t) -> Bool:
    return Darwin.kill(pid, 0) == 0

  private func windowExistsInState(wid: UInt32) async -> Bool:
    let state = await stateManager.getState()
    return state.windows[String(wid)] != nil

  private func findGhosttyWindow(byPID pid: pid_t) async -> UInt32?:
    // Query StateManager for windows owned by this PID with matching title
    let state = await stateManager.getState()
    for (widStr, window) in state.windows:
      if window.pid == pid:
        if let title = window.title, title.contains(ghosttyTitle):
          return window.id
    // Fallback: if PID matches and only one window, use it
    let pidWindows = state.windows.values.filter { $0.pid == pid }
    if pidWindows.count == 1:
      return pidWindows.first?.id
    return nil

  private func findAnyGhosttyWindow() async -> (UInt32, pid_t)?:
    // Search all windows for Ghostty with matching title
    let state = await stateManager.getState()
    for (_, window) in state.windows:
      let pidStr = String(window.pid)
      if let app = state.applications[pidStr],
         app.bundleIdentifier == ghosttyBundleID:
        if let title = window.title, title.contains(ghosttyTitle):
          return (window.id, window.pid)
    return nil

  // MARK: - Ghostty Launch (Tier 4)

  private func launchGhostty() async -> CommandResult:
    log "term.launch"

    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [
      "-na", "Ghostty.app",
      "--args",
      "--title=grid:scratch",
      "--window-decoration=none",
      "--quit-after-last-window-closed=true",
      "--env=GRID_TERMINAL=scratch",
      "--command=\(shell) -l -c 'tmux new-session -A -s grid-scratch'"
    ]

    do:
      try process.run()
    catch:
      log "err.term.launch" with error
      return .error("failed to launch Ghostty")

    // Poll for window appearance
    var foundWID: UInt32? = nil
    var foundPID: pid_t? = nil
    for attempt in 0..<pollMaxAttempts:
      try? await Task.sleep(for: .milliseconds(pollInterval))
      if let (wid, pid) = await findAnyGhosttyWindow():
        foundWID = wid
        foundPID = pid
        break

    guard let wid = foundWID, let pid = foundPID else:
      log "err.term.timeout"
      return .error("Ghostty window did not appear within 5s")

    // Save state
    savedWindowID = wid
    savedPID = pid
    isHidden = false

    // Position: 80% x 60% centered on active display
    let displayUUID = await getActiveDisplayUUID()
    let targetFrame = await computeDefaultFrame(displayUUID: displayUUID)

    if let element = windowManipulator.getAXElement(pid: pid, windowID: wid):
      windowManipulator.setWindowFrame(element: element, frame: targetFrame)

    // Set layer to "above" so terminal floats
    windowManipulator.mssClient.setWindowLayer(windowID: wid, layer: .above)

    // Focus the new window
    windowManipulator.focusWindow(pid: pid, windowID: wid)

    // Save the initial frame
    if let uuid = displayUUID:
      saveFrame(displayUUID: uuid, frame: targetFrame)

    log "term.launched" with wid, pid
    return .ok("launched")

  // MARK: - Display and Frame Helpers

  private func getActiveDisplayUUID() async -> String?:
    let state = await stateManager.getState()
    return state.metadata.activeDisplayUUID

  private func getDisplayUUID(forWindow wid: UInt32) async -> String?:
    let state = await stateManager.getState()
    return state.windows[String(wid)]?.displayUUID

  private func getCurrentFrame(wid: UInt32) async -> CGRect?:
    let state = await stateManager.getState()
    return state.windows[String(wid)]?.frame

  private func computeDefaultFrame(displayUUID: String?) async -> CGRect:
    let state = await stateManager.getState()
    // Find the display's visible frame
    var visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    if let uuid = displayUUID:
      for display in state.displays:
        if display.uuid == uuid:
          visibleFrame = display.visibleFrame ?? display.frame ?? visibleFrame
          break

    // Compute 80% x 60% centered
    let width = visibleFrame.width * defaultWidthRatio
    let height = visibleFrame.height * defaultHeightRatio
    let x = visibleFrame.origin.x + (visibleFrame.width - width) / 2
    let y = visibleFrame.origin.y + (visibleFrame.height - height) / 2
    return CGRect(x: x, y: y, width: width, height: height)

  // MARK: - Frame Persistence

  private func saveFrame(displayUUID: String, frame: CGRect):
    displayFrames[displayUUID] = frame
    flushFramesToDisk()

  private func restoreFrame(displayUUID: String) -> CGRect?:
    return displayFrames[displayUUID]

  private func loadFramesFromDisk():
    let path = framePersistencePath
    guard FileManager.default.fileExists(atPath: path) else: return

    do:
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      let decoded = try JSONDecoder().decode(Dictionary<String, FrameData>.self, from: data)
      for (uuid, fd) in decoded:
        displayFrames[uuid] = CGRect(x: fd.x, y: fd.y, width: fd.w, height: fd.h)
      log "term.frames.loaded" with count
    catch:
      log "err.term.frames.load" with error

  private func flushFramesToDisk():
    var encoded: Dictionary<String, FrameData> = empty
    for (uuid, rect) in displayFrames:
      encoded[uuid] = FrameData(x: rect.origin.x, y: rect.origin.y,
                                w: rect.size.width, h: rect.size.height)

    do:
      let data = try JSONEncoder().encode(encoded)
      let dir = (framePersistencePath as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: framePersistencePath))
    catch:
      log "err.term.frames.save" with error

// MARK: - Supporting Types

private struct FrameData: Codable:
  let x: CGFloat
  let y: CGFloat
  let w: CGFloat
  let h: CGFloat
```

## Design Notes

1. **Actor vs class**: Actor is chosen because terminal state (savedWID, savedPID, isHidden, toggling, displayFrames) is mutable and accessed from multiple async contexts (BFD hotkey thread, CLI RPC, reconciler events). The actor provides safe serialization without manual locking.

2. **Toggling guard**: Even though actor serialization prevents true concurrency, `toggle()` has suspension points (awaits). A rapid second call could interleave at any suspension point. The `toggling` flag prevents this by early-returning the second call.

3. **GridReconciler as dependency**: GridReconciler is a plain class, not Sendable. Storing it in the actor requires `@unchecked Sendable` conformance on GridTerminalManager or marking the property as `nonisolated`. Since other actors in the codebase (GridReconciler's own callers) already cross this boundary, follow the existing pattern. The `setSuppressed` calls are synchronous and thread-safe (they set a simple Bool).

4. **Hide mechanics**: We use MSS opacity (proven cross-process) combined with AX position move to (-10000, -10000). This avoids the orderWindowOut issue where Ghostty fights re-ordering. The window remains "ordered in" from the OS perspective, but invisible and unreachable.

5. **Frame persistence**: Simple JSON file at `~/.local/state/thegrid/terminal-frames.json`. Flushed synchronously on each save (writes are infrequent -- only on hide). Loaded once on actor init.

6. **Tier 2/3 window lookup**: Queries StateManager.getState() directly rather than using the `window.find` RPC, because that RPC filters out hidden windows and windows with frame.height < 100.

7. **Default frame on launch**: Uses active display's `visibleFrame` (excludes menu bar/dock) for 80%x60% centered calculation. Falls back to hardcoded 1920x1080 if no display info available.

8. **Layer setting**: Only set on initial launch (tier 4). On subsequent show operations, the layer should persist since we never change it.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (single actor approach, depth check passed)
- [x] Ready for implementation
