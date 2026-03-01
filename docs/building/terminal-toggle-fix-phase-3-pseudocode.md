# Phase 3 Pseudocode: Terminal Toggle Fix

## 3a. New function: positionTerminalOnDisplay

```
FUNC positionTerminalOnDisplay(ctx, c, windowID int, display *client.DisplayInfo, resize bool):
  logData = {wid: windowID, displayUUID: display.UUID}

  // Use visibleFrame (excludes menu bar/dock), fall back to frame
  vf = display.VisibleFrame
  IF vf.Width == 0: vf = display.Frame
  IF vf.Width == 0: log "no_bounds", return

  // Load config for display offset
  cfg, err = gridConfig.LoadConfig("")
  offset = {0, 0}
  IF err == nil:
    offset = cfg.GetDisplayOffset(display.UUID, display.Name)

  IF resize:
    // Fresh launch: 80% x 60% centered
    winW = vf.Width * 0.8
    winH = vf.Height * 0.6
    x = vf.X + (vf.Width - winW) / 2 + offset.X
    y = vf.Y + (vf.Height - winH) / 2 + offset.Y
    UpdateWindow(wid, {x, y, width: winW, height: winH})
  ELSE:
    // Toggle show: move to display's current space + center
    winW = vf.Width * 0.8
    winH = vf.Height * 0.6
    x = vf.X + (vf.Width - winW) / 2 + offset.X
    y = vf.Y + (vf.Height - winH) / 2 + offset.Y
    UpdateWindow(wid, {spaceId: display.CurrentSpaceID, x, y})

  logData["result"] = "positioned"
  logData["offset"] = {x: offset.X, y: offset.Y}
  logData["placed"] = {x, y}
  log "term.position" with logData
```

## 3b. Rewrite Tier 1

```
IF savedPID > 0 && pidAlive && savedWID > 0:
  // Capture active display BEFORE any show/focus
  activeDisplay, displayErr = c.GetActiveDisplay(ctx)

  params = {"windowId": string(savedWID)}
  result, err = c.CallMethod("window.isOrderedIn", params)
  IF err == nil:
    isOrderedIn = result["isOrderedIn"].(bool)
    onCurrentSpace = isWindowOnSpace(result, activeDisplay)

    IF isOrderedIn && onCurrentSpace:
      // Visible on current space → hide
      c.CallMethod("window.hide", params)
      logTerminal(1, "hide", nil)
      return

    ELSE:
      // Hidden OR on different space → move + show + position
      IF displayErr == nil && activeDisplay != nil:
        positionTerminalOnDisplay(ctx, c, savedWID, activeDisplay, false)
      c.CallMethod("window.show", params)
      logTerminal(1, "show", {onCurrentSpace})
      return

  // RPC failed → stale WID, fall through
```

## 3b helper: isWindowOnSpace

```
FUNC isWindowOnSpace(result map, display *DisplayInfo) bool:
  IF display == nil: return false
  spacesRaw, ok = result["spaces"].([]interface{})
  IF !ok: return false
  FOR space IN spacesRaw:
    IF string(space) == display.CurrentSpaceID: return true
  return false
```

## 3c. Rewrite Tier 2+3 to use FindWindow

```
Tier 2: IF savedPID > 0 && pidAlive:
  wid, _, found, err = c.FindWindow(ctx, "Ghostty", "grid-terminal")
  IF err == nil && found:
    saveTerminalWID(widFile, wid)
    params = {"windowId": string(wid)}
    c.CallMethod("window.hide", params)
    logTerminal(2, "hide", {foundWid: wid})
    return

Tier 3: No saved state
  wid, pid, found, err = c.FindWindow(ctx, "Ghostty", "grid-terminal")
  IF err == nil && found:
    saveTerminalWID(widFile, wid)
    saveTerminalPID(pidFile, pid)
    params = {"windowId": string(wid)}
    c.CallMethod("window.hide", params)
    logTerminal(3, "hide", {wid, pid})
    return
```

## 3d. Rewrite Tier 4 poll

```
activeDisplay, _ = c.GetActiveDisplay(ctx)
// Launch Ghostty...
// Poll with lightweight window.find
FOR i = 0; i < 50; i++:
  sleep 100ms
  wid, pid, found, err = c.FindWindow(ctx, "Ghostty", "grid-terminal")
  IF found: newWinID = wid; newPID = pid; break

IF activeDisplay != nil:
  positionTerminalOnDisplay(ctx, c, newWinID, activeDisplay, true)
setLayer("above")
// NO setSticky
```

## 3e. Delete dead functions
- moveTerminalToActiveDisplay
- centerTerminalOnDisplay
- findTerminalInDump
- toFloat64ForTerminal
