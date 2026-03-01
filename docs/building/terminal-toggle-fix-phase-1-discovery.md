# Phase 1 Discovery: Server RPC Methods

## Key Files
- `grid-server/Sources/GridServer/MessageHandler.swift` (1084 lines) - RPC handler registration
- `grid-server/Sources/GridServer/StateModels.swift` - State structures
- `grid-server/Sources/GridServer/Models/Message.swift` - Message protocol
- `grid-server/Sources/GridServer/StateManager.swift` - State access

## Handler Registration Pattern
```swift
register(method: "method.name") { request, completion in
    guard let params = request.params else {
        completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
        return
    }
    Task {
        let state = await StateManager.shared.getState()
        completion(Response(id: request.id, result: AnyCodable([
            "key": "value"
        ])))
    }
}
```
- Handlers stored in `handlers: [String: RequestHandler]` dictionary
- Registered in `registerBuiltInHandlers()` at line 84
- Handler type: `(Request, @escaping (Response) -> Void) -> Void`

## Response Formatting
- Success: `Response(id: request.id, result: AnyCodable([...]))`
- Error: `Response(id: request.id, error: ErrorInfo(code: -32602, message: "..."))`
- Error codes: -32602 (invalid params), -32603 (internal), -32601 (method not found), -32001 (window not found), -32000 (generic)

## State Structure

### StateMetadata (StateModels.swift:264-284)
```swift
struct StateMetadata: Codable {
    var lastUpdate: Date
    var version: String
    var connectionID: Int32
    var focusedWindowID: UInt32?
    var activeDisplayUUID: String?
    var activeSpaceID: UInt64?
}
```

### DisplayState (StateModels.swift:36-77)
```swift
struct DisplayState: Codable {
    let uuid: String
    var currentSpaceID: UInt64
    var spaces: [UInt64]
    var displayID: UInt32?
    var name: String?
    var frame: CGRect?
    var visibleFrame: CGRect?
    var backingScaleFactor: CGFloat?
    var isMain: Bool?
    // ... more fields
}
```
- Access: `state.displays` (array), find by UUID: `state.displays.first { $0.uuid == uuid }`

### WindowState (StateModels.swift:170-260)
```swift
struct WindowState: Codable {
    let id: UInt32
    var frame: CGRect
    var pid: pid_t
    var appName: String?
    var title: String?
    var isHidden: Bool
    var isMinimized: Bool
    var spaces: [UInt64]
    // ... more fields
}
```
- Windows dict keyed by String (UInt32 as string): `state.windows[String(windowID)]`

## window.isOrderedIn Handler (MessageHandler.swift:439-461)
```swift
register(method: "window.isOrderedIn") { request, completion in
    guard let params = request.params,
          let windowId = params["windowId"]?.value as? String,
          let windowID = UInt32(windowId) else { ... }
    Task {
        let state = await StateManager.shared.getState()
        var value: UInt8 = 0
        let err = SLSWindowIsOrderedIn(state.metadata.connectionID, windowID, &value)
        if err == .success {
            completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "isOrderedIn": value != 0])))
        } else { ... }
    }
}
```

## Trace Context
- Extracted from `request.params["_trace"]` (optional)
- Contains `tid` and `sid` for span correlation
