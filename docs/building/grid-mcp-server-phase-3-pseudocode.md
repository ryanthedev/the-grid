# Pseudocode: Phase 3 - Screenshot + Recording Tools

## DW Verification

| DW-ID | Done-When Item | Status | Pseudocode Section |
|-------|---------------|--------|-------------------|
| DW-3.1 | `grid.screenshot` captures current screen/cell/window and returns base64 image content | COVERED | grid.screenshot Tool Definition + handleScreenshot() |
| DW-3.2 | `grid.record.start` with format=gif initiates a recording and returns status | COVERED | Recording Tools (already working via callRPC) |
| DW-3.3 | `grid.record.stop` stops recording and returns the output file path | COVERED | Recording Tools (already working via callRPC) |
| DW-3.4 | MCP response for `grid.screenshot` contains `type: "image"` and valid base64 PNG data | COVERED | handleScreenshot() image content return |

**All items COVERED:** YES

## Files to Create/Modify

- `grid-mcp/Sources/GridMCP/Tools/GridTools.swift` — add `grid.screenshot` definition + dispatch intercept + implementation

No new files needed — GridTools.swift is the right place since screenshot is a `grid.*` tool.

## Pseudocode

### GridTools.swift — grid.screenshot Tool Definition [DW-3.1, DW-3.4]

```
Add to GridTools.definitions array (after recording tools):

Tool(
    name: "grid.screenshot",
    description: "Capture a screenshot and return it as an inline image. Target: 'full' (entire screen), 'window' (specific window by ID), 'cell' (grid cell by ID).",
    inputSchema: objectSchema(
        properties: [
            "target": prop("string", description: "What to capture", enumValues: ["full", "window", "cell"]),
            "id": prop("string", description: "Window ID (for target=window) or cell ID (for target=cell)"),
            "cursor": prop("boolean", description: "Include cursor in screenshot (full screen only)"),
            "display": prop("integer", description: "Display index (0-based) for full-screen capture"),
        ]
    ),
    annotations: .init(readOnlyHint: true)
)
```

### GridTools.swift — Dispatch Intercept [DW-3.1]

```
In GridTools.handle():
  // Before the callRPC fallthrough, add:
  if name == "grid.screenshot" {
      return handleScreenshot(arguments: arguments, rpcClient: rpcClient)
  }
  // ... existing grow/shrink check ...
  return callRPC(...)
```

### GridTools.swift — handleScreenshot() [DW-3.1, DW-3.4]

```
private static func handleScreenshot(
    arguments: [String: Value]?,
    rpcClient: RPCClient
) -> CallTool.Result

  // 1. Parse params
  let target = arguments["target"]?.stringValue ?? "full"
  let id = arguments["id"]?.stringValue  // nil means not provided
  let includeCursor = arguments["cursor"]?.boolValue ?? false
  let displayIndex = arguments["display"]?.intValue  // nil = default display

  // 2. Build temp output path
  let uuid = UUID().uuidString
  let outPath = "/tmp/grid-screenshot-\(uuid).png"

  // 3. Build screencapture args based on target
  var args: [String] = ["-x"]  // silent mode

  switch target:
  case "full":
    if includeCursor { args.append("-C") }
    if let displayIndex = displayIndex { args += ["-D", "\(displayIndex + 1)"] }
    // -D flag is 1-based in screencapture
    args.append(outPath)

  case "window":
    guard let windowIdStr = id, let windowId = UInt32(windowIdStr) else:
      return errorResult("window target requires a numeric 'id' parameter")
    args += ["-l", "\(windowId)"]
    args.append(outPath)

  case "cell":
    guard let cellId = id else:
      return errorResult("cell target requires 'id' parameter")
    // Resolve cell bounds via dump RPC
    let cellBounds = resolveCellBounds(cellId: cellId, rpcClient: rpcClient)
    guard let bounds = cellBounds else:
      return errorResult("could not resolve bounds for cell '\(cellId)'")
    // screencapture -R x,y,w,h  (integer coordinates)
    let x = Int(bounds.x), y = Int(bounds.y), w = Int(bounds.w), h = Int(bounds.h)
    args += ["-R", "\(x),\(y),\(w),\(h)"]
    args.append(outPath)

  default:
    return errorResult("unknown target: \(target)")

  // 4. Run screencapture synchronously
  do:
    try runProcessSync("/usr/sbin/screencapture", arguments: args)
  catch:
    return errorResult("screencapture failed: \(error)")

  // 5. Read PNG file and base64-encode
  defer { try? FileManager.default.removeItem(atPath: outPath) }

  guard let pngData = FileManager.default.contents(atPath: outPath), !pngData.isEmpty else:
    return errorResult("screenshot file not found or empty")

  let base64String = pngData.base64EncodedString()

  // 6. Return as MCP image content
  return CallTool.Result(
    content: [
      .image(data: base64String, mimeType: "image/png", annotations: nil, _meta: nil)
    ]
  )
```

### GridTools.swift — resolveCellBounds() helper [DW-3.1]

```
// Calls dump RPC and extracts cell bounds from grid state.
// Returns (x, y, w, h) as doubles, or nil if not found.
private static func resolveCellBounds(
    cellId: String,
    rpcClient: RPCClient
) -> (x: Double, y: Double, w: Double, h: Double)?

  // Call dump to get full grid state
  do:
    let result = try rpcClient.call("dump")
    // result["grid"]["spaces"] -> [spaceID: { cells: { cellID: { x, y, w, h } } }]
    // Walk result to find the cell
    guard let grid = result["grid"] as? [String: Any],
          let spaces = grid["spaces"] as? [String: Any] else: return nil

    for (_, spaceValue) in spaces:
      guard let space = spaceValue as? [String: Any],
            let cells = space["cells"] as? [String: Any],
            let cell = cells[cellId] as? [String: Any] else: continue

      // Cell has frame: {x, y, w, h} or x, y, width, height at top level
      // Try both common layouts
      if let x = cell["x"] as? Double,
         let y = cell["y"] as? Double,
         let w = (cell["w"] ?? cell["width"]) as? Double,
         let h = (cell["h"] ?? cell["height"]) as? Double:
        return (x: x, y: y, w: w, h: h)

    return nil  // cell not found in any space
  catch:
    return nil
```

Note: The dump RPC returns the full WM state. We need to navigate to grid cell bounds. Looking at the actual structure will be needed — if the structure differs from assumptions, fallback to `metadata.get` + layout calculation.

### GridTools.swift — runProcessSync() helper [DW-3.1, DW-3.4]

```
// Run an external process synchronously (blocking until exit).
// Throws if exit code != 0.
private static func runProcessSync(_ executable: String, arguments: [String]) throws

  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.launch()  // or process.run()
  process.waitUntilExit()

  guard process.terminationStatus == 0 else:
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    throw ScreenshotError.processFailed(process.terminationStatus, output)
```

### GridTools.swift — Error Type [DW-3.1]

```
// Private error enum for screenshot errors
private enum ScreenshotError: Error {
    case processFailed(Int32, String)
    case boundsResolutionFailed(String)
}

// Helper to build error result
private static func errorResult(_ message: String) -> CallTool.Result:
  return CallTool.Result(
    content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)],
    isError: true
  )
```

## Recording Tools (DW-3.2, DW-3.3)

`grid.record.start`, `grid.record.stop`, `grid.record.toggle` are already implemented via `callRPC` passthrough in `GridTools.handle()`. The grid-server RPC handlers are fully registered and return appropriate JSON results:
- `grid.record.start` → `{"action": "started"}` or `RecordingResult` JSON
- `grid.record.stop` → `{"filePath": "...", "format": "...", "size": N, "duration": N}`
- `grid.record.toggle` → `{"action": "started"}` or `RecordingResult` JSON

No code changes needed for DW-3.2/DW-3.3 — they work as-is.

## Design Notes

- `runProcessSync` mirrors the pattern in GridRecorder's `runProcess()` — synchronous process execution with pipe for error capture
- `resolveCellBounds` relies on the dump RPC's grid state structure. We need to inspect the actual dump response to get the right key path. Alternative: call `grid.state.show` which might have a cleaner structure.
- The `screencapture -l` flag takes a CGWindowID (UInt32). The `id` param for `window` target must be a numeric window ID matching what `window.find` and `dump` return.
- Temp files are cleaned up with `defer` after base64 encoding. If encoding fails, the defer still runs.
- No async/await — RPCClient.call() is synchronous. Process.waitUntilExit() is synchronous. This matches the existing pattern (callRPC is synchronous).
- Display index: screencapture uses 1-based `-D` flag. We accept 0-based from the user and add 1.
