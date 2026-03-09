# Pseudocode: Phase 2 - Wire GridTerminalManager into Server

## Files to Create/Modify

1. `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` (edit)
2. `grid-server/Sources/GridServer/main.swift` (edit)
3. `grid-server/Sources/GridServer/MessageHandler.swift` (edit)

## Pseudocode

### GridCommandRouter.swift

**Edit 1: Add terminalManager stored property (after line 44)**

```
After the gridRecorder property declaration:
  Add a private stored property for gridTerminalManager of type GridTerminalManager
```

**Edit 2: Add terminalManager constructor parameter (line 65, after gridRecorder param)**

```
After the gridRecorder parameter in init():
  Add terminalManager parameter of type GridTerminalManager
  Assign self.terminalManager = terminalManager in the init body (after line 78)
```

Note: This brings the constructor to 13 parameters. This is above the 7-param guideline
but GridCommandRouter is a wiring hub -- every feature module in the server is injected
through it. Adding one more follows the established pattern. The alternative (a config
struct or dictionary) would add indirection without reducing actual complexity.

**Edit 3: Replace NSDistributedNotification with terminalManager.toggle() (lines 173-175)**

```
In the dispatch() switch on parsed.domain:
  case "terminal":
    Await terminalManager.toggle() and return its CommandResult
    // Remove the NSDistributedNotification post entirely
```

The terminal manager already handles reconciler suppression internally, so no
`setSuppressed` wrapper is needed at the router level (unlike the "focus" case
which wraps at line 154-156).

### main.swift

**Edit 1: Construct GridTerminalManager (after line 165, before router construction)**

```
After gridRecorder construction and before commandRouter construction:
  Create gridTerminalManager by calling GridTerminalManager init with:
    windowManipulator: windowManipulator (already exists at line 159)
    stateManager: StateManager.shared (already in scope)
    gridReconciler: gridReconciler (already in scope)
```

**Edit 2: Pass terminalManager to GridCommandRouter constructor (line 167-180)**

```
In the GridCommandRouter constructor call:
  Add terminalManager: gridTerminalManager parameter
  Insert after gridRecorder parameter (last position before closing paren)
```

### MessageHandler.swift

**Edit 1: Register grid.terminal RPC (before the closing jlog at line 1795)**

```
Before the "grid.rpc.registered" log line:
  Register method "grid.terminal" with a closure that:
    Builds command string "@terminal" (no params needed -- toggle has no arguments)
    Calls dispatchAndRespond with the request, command string, and completion
```

This follows the simplest existing pattern -- `grid.layout.cycle` at line 1504 is
the closest analog (no required params, just dispatches a fixed command string).

## Design Notes

**Design-it-twice consideration:** The wiring here is pure plumbing -- there is exactly
one correct way to wire a new feature module into this server's existing architecture.
The three files each have a single, well-established pattern for adding new functionality.
No alternative designs are meaningful; this is mechanical extension.

**Information hiding:** GridTerminalManager remains a fully opaque actor from the router's
perspective. The router knows only that it has a `toggle()` method returning `CommandResult`.
All terminal state, hide/show mechanics, frame persistence, and Ghostty process management
are hidden inside the actor.

**Parameter count:** GridCommandRouter now has 13 constructor parameters. This is a known
trade-off of the hub pattern. The router's sole purpose is to receive all feature modules
and dispatch to them -- it is inherently a high-fan-in integration point. Reducing
parameters would require either a registry pattern (adds complexity, loses compile-time
safety) or a builder pattern (adds ceremony for no practical benefit in this context).

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (mechanical wiring, no novel design decisions)
- [x] Ready for implementation
