# Phase 1+2 Discovery: orderWindowOut + isOrderedIn

## MSSClient.swift
**File:** `grid-server/Sources/GridServer/MSSClient.swift`

### Existing orderWindowToFront (lines 267-277)
```swift
func orderWindowToFront(_ windowID: UInt32) -> Bool {
    queue.sync {
        var wid = windowID
        return mss_window_order_in(ctx, &wid, 1)
    }
}
```

### Pattern: queue.sync wrapper, returns Bool

## mss.h / mss_types.h
**Header:** `grid-server/include/mss/mss.h` line 253
```c
bool mss_window_order(mss_context *ctx, uint32_t wid,
                      enum mss_window_order order, uint32_t relative_wid);
```

**Constants:** `grid-server/include/mss/mss_types.h` lines 23-28
```c
enum mss_window_order {
    MSS_ORDER_OUT   = 0,
    MSS_ORDER_ABOVE = 1,
    MSS_ORDER_BELOW = -1
};
```

## MacOSAPIs.swift
**File:** `grid-server/Sources/GridServer/MacOSAPIs.swift`

- Line 54: `typealias SLSWindowIsOrderedIn_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> CGError`
- Line 126: `private let _SLSWindowIsOrderedIn: SLSWindowIsOrderedIn_t? = loadSymbol("SLSWindowIsOrderedIn")`
- Lines 235-237: Wrapper `func SLSWindowIsOrderedIn(_ cid: Int32, _ wid: UInt32, _ value: UnsafeMutablePointer<UInt8>) -> CGError`

## MessageHandler.swift RPC Pattern
**File:** `grid-server/Sources/GridServer/MessageHandler.swift`

### Registration pattern (setter example - window.setOpacity):
```swift
register(method: "window.setOpacity") { request, completion in
    guard let params = request.params else { ... }
    guard let windowId = params["windowId"]?.value as? String,
          let windowID = UInt32(windowId) else { ... }

    Task {
        let state = await StateManager.shared.getState()
        let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

        if manipulator.mssClient.someMethod(windowID) {
            completion(Response(id: request.id, result: AnyCodable([...])))
        } else {
            completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "...")))
        }
    }
}
```

### Getter pattern returns data in result dict
