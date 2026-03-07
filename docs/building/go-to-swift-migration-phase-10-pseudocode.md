# Pseudocode: Phase 10 - Thin Swift CLI

## Design: RPCClient

### Approaches Considered
1. **Synchronous Foundation socket** -- Use `FileHandle` with Unix socket, synchronous read/write, newline-delimited JSON. Simple, no async needed.
2. **NIO-based async client** -- Use SwiftNIO for async socket IO. More infrastructure, handles backpressure.
3. **URLSession with custom protocol** -- Wrap Unix socket in URLSession custom protocol handler.

### Comparison
| Criterion | A (Foundation sync) | B (NIO async) | C (URLSession) |
|-----------|---------------------|---------------|-----------------|
| Interface simplicity | Simple: `call(method, params) -> Result` | Needs event loop setup | Complex adapter layer |
| Dependencies | None (Foundation only) | SwiftNIO package | None but awkward fit |
| Caller ease of use | Trivial -- blocking is fine for CLI | Overkill for request-response | Overkill |
| Lines of code | ~80-100 | ~200+ | ~150+ |

### Choice: A (Foundation synchronous)
Rationale: CLI is synchronous by nature. Each command sends one request and prints one response. No need for async IO, event loops, or backpressure. Foundation socket with `FileHandle` is the simplest approach. Sacrificing async capability is irrelevant for a CLI tool.

### Depth Check
- Interface methods: 2 (`connect`, `call`)
- Hidden details: socket connection, JSON envelope marshaling, newline framing, error extraction
- Common case complexity: simple -- `client.call("grid.focus", ["direction": "left"])`

---

## Design: Command File Organization

### Approaches Considered
1. **One file per command group** -- `FocusCommand.swift`, `LayoutCommand.swift`, etc. Each contains the parent + subcommands.
2. **One file per leaf command** -- `FocusLeftCommand.swift`, `FocusRightCommand.swift`, etc.
3. **Single file** -- All commands in `main.swift`.

### Comparison
| Criterion | A (per group) | B (per leaf) | C (single file) |
|-----------|---------------|--------------|-----------------|
| Navigation | Good -- ~10 files | Too many (~30+ files) | One 1000+ line file |
| Cohesion | Related commands together | Scattered | Everything mixed |
| Boilerplate | Moderate | High (many files) | Low |

### Choice: A (one file per command group)
Rationale: Matches the RPC namespace grouping (`grid.focus.*`, `grid.layout.*`, etc.). Each file is self-contained for its domain. Keeps file count manageable.

---

## Files to Create/Modify

### Modify
- `grid-server/Package.swift` -- add `GridCLI` executable target

### Create
- `grid-server/Sources/GridCLI/main.swift` -- entry point
- `grid-server/Sources/GridCLI/RPCClient.swift` -- socket client
- `grid-server/Sources/GridCLI/FocusCommand.swift`
- `grid-server/Sources/GridCLI/LayoutCommand.swift`
- `grid-server/Sources/GridCLI/CellCommand.swift`
- `grid-server/Sources/GridCLI/WindowCommand.swift`
- `grid-server/Sources/GridCLI/ResizeCommand.swift`
- `grid-server/Sources/GridCLI/RecordCommand.swift`
- `grid-server/Sources/GridCLI/StateCommand.swift`
- `grid-server/Sources/GridCLI/ConfigCommand.swift`
- `grid-server/Sources/GridCLI/PingCommand.swift`
- `grid-server/Sources/GridCLI/PickCommand.swift`

## Pseudocode

### Package.swift Changes

```
Add to products:
  executable "grid-cli" targeting "GridCLI"

Add to targets:
  executableTarget "GridCLI"
    depends on ArgumentParser
    path "Sources/GridCLI"
```

### RPCClient.swift

```
RPCClient class:
  properties:
    socketPath: String (default "/tmp/grid-server.sock")
    timeout: TimeInterval (default 30)
    fileHandle: FileHandle? (nil until connected)

  init(socketPath, timeout):
    store both

  connect():
    Create Unix domain socket via socket(AF_UNIX, SOCK_STREAM, 0)
    Build sockaddr_un with socketPath
    Call POSIX connect()
    Wrap file descriptor in FileHandle for reading/writing
    If connection fails, throw descriptive error

  call(method: String, params: [String: Any] = [:]) throws -> [String: Any]:
    If not connected, call connect()
    Build envelope dictionary:
      "type": "request"
      "request": {
        "id": UUID().uuidString
        "method": method
        "params": params
      }
    Serialize envelope to JSON data
    Append newline byte
    Write data to fileHandle
    Read response line from fileHandle (read until newline)
    Parse JSON response into dictionary
    Verify response type is "response"
    Extract response object
    If response has "error" field:
      Throw error with code and message from error object
    Return response "result" dictionary (or empty dict if nil)

  close():
    Close fileHandle if open
    Set fileHandle to nil

  Helper -- readLine() -> Data:
    Read bytes one at a time (or in chunks) until newline found
    Return accumulated data excluding the newline
    If timeout exceeded or EOF, throw error
```

### main.swift

```
import ArgumentParser

Top-level command "GridCLI" as ParsableCommand:
  configuration:
    commandName: "thegrid"
    abstract: "Grid window manager CLI"
    subcommands: [
      PingCommand, FocusCommand, LayoutCommand, CellCommand,
      WindowCommand, ResizeCommand, RecordCommand, StateCommand,
      ConfigCommand, PickCommand
    ]

  options:
    --socket: String = "/tmp/grid-server.sock"
    --json: Bool = false
    --timeout: Int = 30

Global helper functions:

  makeClient(from options) -> RPCClient:
    Return RPCClient(socketPath: options.socket, timeout: options.timeout)

  printResult(_ result: [String: Any], json: Bool):
    If json mode or result has complex nested data:
      Serialize result to pretty JSON, print to stdout
    Else:
      Print single-line confirmation (e.g., "ok")

  printError(_ error: Error):
    Print error message to stderr
    Exit with code 1
```

### PingCommand.swift

```
PingCommand as ParsableCommand:
  configuration: commandName "ping"

  @OptionGroup var globals: GridCLI.GlobalOptions

  run():
    Create RPCClient from globals
    Record start time
    Call client.call("ping")
    Calculate elapsed time
    If json mode:
      Add "elapsed_ms" to result
      Print JSON
    Else:
      Print "pong" and elapsed time
```

### FocusCommand.swift

```
FocusCommand as ParsableCommand:
  configuration:
    commandName: "focus"
    subcommands: [FocusDirection, FocusCycle, FocusCell]

  FocusDirection as ParsableCommand:
    configuration:
      commandName: "left" (also "right", "up", "down" via separate structs, OR
        use a single struct with direction as argument)

    Actually: create four separate leaf commands FocusLeft, FocusRight, FocusUp, FocusDown
    OR: one FocusDirection with @Argument direction: String

    Decision: Use one struct with direction as the command name approach:
      Four small structs sharing a helper, matching Go pattern.

    FocusLeft/Right/Up/Down as ParsableCommand:
      @Flag --wrap: Bool = true
      @Flag --extend: Bool = false
      @Flag --mouse: Bool = false
      @OptionGroup var globals

      run():
        Create RPCClient
        Build params: { "direction": "<left|right|up|down>", "wrap": wrap, "extend": extend, "mouse": mouse }
        Call client.call("grid.focus", params)
        Print "ok" or JSON result

  FocusNext as ParsableCommand:
    commandName: "next"
    @Flag --mouse: Bool = false
    run():
      Call client.call("grid.focus.cycle", { "forward": true })

  FocusPrev as ParsableCommand:
    commandName: "prev"
    @Flag --mouse: Bool = false
    run():
      Call client.call("grid.focus.cycle", { "forward": false })

  FocusCell as ParsableCommand:
    commandName: "cell"
    @Argument cell: String
    @Option --space: String?
    run():
      Build params with cell, optional space
      Call client.call("grid.focus.cell", params)
```

### LayoutCommand.swift

```
LayoutCommand as ParsableCommand:
  configuration:
    commandName: "layout"
    subcommands: [LayoutApply, LayoutList, LayoutCurrent, LayoutRefresh, LayoutCycle, LayoutEdit]

  LayoutApply:
    @Argument layout: String
    @Option --strategy: String?
    run():
      Call client.call("grid.layout.apply", { "layout": layout, "strategy": strategy })

  LayoutList:
    run():
      Call client.call("grid.layout.list")
      Print result layouts

  LayoutCurrent:
    run():
      Call client.call("grid.layout.current")
      Print current layout name and space

  LayoutRefresh:
    @Option --display: String?
    run():
      Call client.call("grid.layout.refresh", { "display": display })

  LayoutCycle:
    run():
      Call client.call("grid.layout.cycle")

  LayoutEdit:
    @Argument layout: String
    run():
      Step 1: Fetch layout definition
        Call client.call("grid.layout.get", { "layout": layout })
        Extract layout dict from result
      Step 2: Serialize to JSON (pretty-printed)
        Write to temp file
      Step 3: Open $EDITOR on temp file
        Get editor from $EDITOR env var, fall back to "vi"
        Run Process with editor and temp file path
        Wait for exit
      Step 4: Read back edited file
        If file unchanged (compare hashes), print "no changes" and return
      Step 5: Parse edited JSON
        Deserialize back to dict
      Step 6: Send update
        Call client.call("grid.layout.update", { "layout": layout, "definition": edited })
        Print confirmation
      Cleanup: remove temp file
```

### CellCommand.swift

```
CellCommand as ParsableCommand:
  commandName: "cell"
  subcommands: [CellSend, CellMode]

  CellSend:
    @Argument direction: String (validated: left, right, up, down)
    run():
      Call client.call("grid.cell.send", { "direction": direction })

  CellMode:
    @Argument mode: String? (optional -- omit to cycle)
    run():
      Build params, include "mode" only if provided
      Call client.call("grid.cell.mode", params)
```

### WindowCommand.swift

```
WindowCommand as ParsableCommand:
  commandName: "window"
  subcommands: [WindowMove, WindowSwap]

  WindowMove as ParsableCommand:
    commandName: "move"
    subcommands: [WindowMoveLeft, WindowMoveRight, WindowMoveUp, WindowMoveDown]

    WindowMoveLeft/Right/Up/Down:
      @Flag --wrap: Bool = true
      @Flag --extend: Bool = false
      run():
        Call client.call("grid.window.move", { "direction": "<dir>", "wrap": wrap, "extend": extend })

  WindowSwap as ParsableCommand:
    commandName: "swap"
    subcommands: [WindowSwapLeft, WindowSwapRight, WindowSwapUp, WindowSwapDown]

    WindowSwapLeft/Right/Up/Down:
      run():
        Call client.call("grid.window.swap", { "direction": "<dir>" })
```

### ResizeCommand.swift

```
ResizeCommand as ParsableCommand:
  commandName: "resize"
  subcommands: [ResizeGrow, ResizeShrink, ResizeReset, ResizeCell]

  ResizeGrow:
    @Argument amount: Double = 0.1
    @Flag --cell: Bool = false
    @Option --direction: String?
    run():
      Call client.call("grid.resize.adjust", { "delta": amount, "cell": cell, "direction": direction })

  ResizeShrink:
    @Argument amount: Double = 0.1
    @Flag --cell: Bool = false
    @Option --direction: String?
    run():
      Call client.call("grid.resize.adjust", { "delta": -amount, "cell": cell, "direction": direction })

  ResizeReset:
    @Flag --all: Bool = false
    @Flag --cells: Bool = false
    run():
      Call client.call("grid.resize.reset", { "all": all, "cell": cells })

  ResizeCell:
    @Argument direction: String
    @Argument amount: Double = 0.1
    run():
      Call client.call("grid.resize.cell", { "direction": direction, "delta": amount })
```

### RecordCommand.swift

```
RecordCommand as ParsableCommand:
  commandName: "record"
  @Argument target: String = "cell"
  @Argument id: String?
  @Option -d --duration: Int = 5
  @Option -o --output: String?
  @Option -f --format: String = "gif"
  @Option --fps: Int = 0
  @Option -w --width: Int = 0
  @Option -q --quality: String = "medium"
  @Option --countdown: Int = 3
  @Flag --cursor: Bool = false
  @Flag --open: Bool = false
  @Flag --follow: Bool = false

  run():
    Build params dict from all options
    Call client.call("grid.record.start", params)
    Print result (file path, size, format)
```

### StateCommand.swift

```
StateCommand as ParsableCommand:
  commandName: "state"
  subcommands: [StateShow, StateReset]

  StateShow:
    run():
      Call client.call("grid.state.show")
      Print result (JSON state)

  StateReset:
    run():
      Call client.call("grid.state.reset")
      Print "ok"
```

### ConfigCommand.swift

```
ConfigCommand as ParsableCommand:
  commandName: "config"
  subcommands: [ConfigShow, ConfigInit]

  ConfigShow:
    run():
      Call client.call("grid.config.show")
      Print result

  ConfigInit (standalone -- no server needed):
    run():
      Determine config path: ~/.config/thegrid/config.yaml
        Use XDG_CONFIG_HOME if set, else ~/.config
      Check if file exists -- if so, print error and exit
      Create directory if needed
      Write default config YAML string (same template as Go version)
      Print "Created config at: <path>"
```

### PickCommand.swift

```
PickCommand as ParsableCommand:
  commandName: "pick"
  run():
    Call client.call("pick.show")
    If result has "cancelled" = true, exit silently
    If result has "selected", print id and title tab-separated
```

## Design Notes

### Global Options Pattern
Use `@OptionGroup` to share socket path, json flag, and timeout across all commands. Define a `GlobalOptions` struct in `main.swift` that each command includes.

### Error Handling
All commands follow the same pattern: call RPC, check for error, print result. The RPCClient throws on connection failure and server errors. Commands catch and print to stderr via ArgumentParser's built-in error handling.

### Output Convention
- `--json` flag: always print full JSON result from server
- Without `--json`: print minimal confirmation ("ok") or key value from result
- Errors always go to stderr

### ConfigInit is Offline
`config init` does not contact the server. It writes a starter YAML file directly. This is the only command that works without a running server.

### Layout Edit uses JSON, not YAML
The Go CLI's `layout edit` used the full config YAML workflow. The Swift CLI's `layout edit` is simpler: fetch layout JSON from `grid.layout.get`, let user edit the JSON in `$EDITOR`, send back via `grid.layout.update`. This avoids needing Yams in the CLI binary. The trade-off is JSON is less human-friendly than YAML, but this is a power-user command.

### Commands Not Ported
Per plan, these Go commands are dropped:
- `show layout`, `show display` (visualization)
- `list windows/spaces/displays/apps` (tables)
- `dump`, `info`, `debug`
- `window get/find/update/to-space/to-display/opacity/layer/sticky/minimize`
- `space create/destroy/focus`
- `event focus` (server handles internally now)
- `render` (JSON stdin layout)
- `terminal`, `view` (remain separate binaries)
- `mouse center/warp` (only used internally by focus commands, server handles directly)

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (RPCClient: sync Foundation socket; Command files: one per group)
- [x] Ready for implementation
