# Phase 1-3 Pseudocode

## Phase 1: MSSClient.orderWindowOut
```
// Same pattern as orderWindowToFront but uses mss_window_order with MSS_ORDER_OUT
func orderWindowOut(windowID):
    queue.sync:
        guard ctx exists
        return mss_window_order(ctx, windowID, MSS_ORDER_OUT, 0)
```

## Phase 2: window.isOrderedIn RPC
```
register "window.isOrderedIn":
    parse windowId from params
    Task:
        get state -> connectionID
        var result: UInt8 = 0
        call SLSWindowIsOrderedIn(cid, windowID, &result)
        return { windowId, isOrderedIn: result != 0 }
```

## Phase 3: window.hide + window.show RPCs
```
register "window.hide":
    parse windowId
    Task:
        get manipulator from state
        mssClient.orderWindowOut(windowID)
        return success/error

register "window.show":
    parse windowId
    Task:
        get manipulator from state
        mssClient.orderWindowToFront(windowID)
        mssClient.focusWindow(windowID)
        return success/error
```
