# Phase 1 Pseudocode: Server RPC Methods

## Location
All handlers go in `MessageHandler.swift`, inside `registerBuiltInHandlers()`.

## 1a. metadata.get — Insert after getServerInfo (after line 128)

```
REGISTER "metadata.get":
  // No params needed
  ASYNC:
    state = StateManager.shared.getState()
    meta = state.metadata
    RESPOND with:
      focusedWindowID: meta.focusedWindowID (as Any, may be nil)
      activeDisplayUUID: meta.activeDisplayUUID (as Any, may be nil)
      activeSpaceID: meta.activeSpaceID.map { String($0) } (convert UInt64 to String for JSON)
      lastUpdate: meta.lastUpdate.timeIntervalSince1970
```

## 1b. display.list — Insert after metadata.get

```
REGISTER "display.list":
  // No params needed
  ASYNC:
    state = StateManager.shared.getState()
    displayArray = state.displays.map { display ->
      dict with:
        uuid: display.uuid
        name: display.name ?? ""
        frame: frameToDict(display.frame)      // {x, y, width, height} or nil
        visibleFrame: frameToDict(display.visibleFrame)
        currentSpaceID: String(display.currentSpaceID)
        isMain: display.isMain ?? false
        backingScaleFactor: display.backingScaleFactor ?? 1.0
    }
    RESPOND with: ["displays": displayArray]

HELPER frameToDict(rect: CGRect?) -> [String: Any]?:
  guard let r = rect else return nil
  return ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
```

## 1c. display.get — Insert after display.list

```
REGISTER "display.get":
  REQUIRE params

  IF params["active"] is true:
    ASYNC:
      state = StateManager.shared.getState()
      activeUUID = state.metadata.activeDisplayUUID
      IF activeUUID is nil:
        ERROR -32000 "No active display"
      display = state.displays.first where uuid == activeUUID
      IF display is nil:
        ERROR -32000 "Active display not found in state"
      RESPOND with display dict (same fields as display.list item)

  ELSE IF params["uuid"] is String:
    ASYNC:
      state = StateManager.shared.getState()
      display = state.displays.first where uuid == params["uuid"]
      IF display is nil:
        ERROR -32000 "Display not found"
      RESPOND with display dict

  ELSE:
    ERROR -32602 "Missing uuid or active param"
```

## 1d. window.find — Insert after display.get

```
REGISTER "window.find":
  REQUIRE params
  appNameFilter = params["appName"] as? String  // optional
  titleFilter = params["title"] as? String      // optional

  IF both nil:
    ERROR -32602 "At least one of appName or title required"

  ASYNC:
    state = StateManager.shared.getState()

    FOR window IN state.windows.values:
      // Apply filters
      IF appNameFilter != nil AND window.appName != appNameFilter: SKIP
      IF titleFilter != nil AND !(window.title?.contains(titleFilter) ?? false): SKIP
      IF window.isHidden: SKIP
      IF (window.frame.height < 100): SKIP  // same as findTerminalInDump

      // Found a match
      RESPOND with:
        found: true
        windowId: String(window.id)
        pid: window.pid
      RETURN

    // No match
    RESPOND with: found: false
```

## 1e. Enhance window.isOrderedIn (line 439-461)

```
MODIFY existing handler at line 456:
  // After SLSWindowIsOrderedIn succeeds:

  // Look up window's spaces from state
  spaces = state.windows[windowId]?.spaces ?? []
  spacesStrings = spaces.map { String($0) }

  RESPOND with:
    windowId: windowId
    isOrderedIn: value != 0
    spaces: spacesStrings  // NEW: array of space ID strings
```

## Helper Function (file-level, before registerBuiltInHandlers)

```swift
private func displayToDict(_ display: DisplayState) -> [String: Any] {
    var dict: [String: Any] = [
        "uuid": display.uuid,
        "name": display.name ?? "",
        "currentSpaceID": String(display.currentSpaceID),
        "isMain": display.isMain ?? false,
        "backingScaleFactor": display.backingScaleFactor ?? 1.0
    ]
    if let f = display.frame {
        dict["frame"] = ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height]
    }
    if let f = display.visibleFrame {
        dict["visibleFrame"] = ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height]
    }
    return dict
}
```
