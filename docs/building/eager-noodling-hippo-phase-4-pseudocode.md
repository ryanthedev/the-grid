# Pseudocode: Phase 4 - Makefile & Cleanup

## Files to Modify
- `Makefile` (edit lines 1, 203)
- `grid-server/Sources/GridServer/main.swift` (remove lines 45-50)
- `grid-server/Package.swift` (remove product, target, and package dependency)
- `grid-server/Sources/GridTerminal/` (delete directory)

## Pseudocode

### Makefile

**Edit 1: Remove `terminal` and `terminal-universal` from `.PHONY` (line 1)**

Replace:
```
.PHONY: help build server cli terminal viewer test clean server-test server-clean run-server install dist dev reset-accessibility setup-signing server-universal cli-universal terminal-universal viewer-universal dist-universal
```
With:
```
.PHONY: help build server cli viewer test clean server-test server-clean run-server install dist dev reset-accessibility setup-signing server-universal cli-universal viewer-universal dist-universal
```

Two removals: `terminal` (after `cli`) and `terminal-universal` (after `cli-universal`).

**Edit 2: Remove `terminal` from `dev` dependencies (line 203)**

Replace:
```
dev: server terminal viewer
```
With:
```
dev: server viewer
```

### grid-server/Sources/GridServer/main.swift

**Edit 1: Remove pkill grid-terminal block (lines 45-50)**

Remove the entire block:
```swift
        // Kill any stale grid-terminal from previous server session
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "-f", "grid-terminal"]
        try? killTask.run()
        killTask.waitUntilExit()
```

Leave the blank line before the grid-picker kill block intact for readability.

### grid-server/Package.swift

**Edit 1: Remove `grid-terminal` product (lines 16-19)**

Remove:
```swift
        .executable(
            name: "grid-terminal",
            targets: ["GridTerminal"]
        ),
```

**Edit 2: Remove SwiftTerm package dependency (line 34)**

Remove:
```swift
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
```

Also remove the trailing comma from the previous line (opentelemetry-swift-core) if SwiftTerm is the last entry. Check: line 33 ends with `"),` and line 34 is SwiftTerm. After removing SwiftTerm, the opentelemetry line should still have its comma removed since it becomes the last dependency. Wait -- Yams is on line 32, opentelemetry is on lines 33, SwiftTerm is on line 34. After removing line 34, opentelemetry on line 33 becomes the last item and its trailing comma must be removed (change `),` to `)`).

Actually, looking at the Package.swift more carefully:
- Line 30: swift-argument-parser (comma)
- Line 31: swift-log (comma)
- Line 32: Yams (comma)
- Line 33: opentelemetry-swift-core (comma)
- Line 34: SwiftTerm (no comma -- last item)

After removing line 34, line 33 (opentelemetry) becomes last and must lose its trailing comma.

**Edit 3: Remove GridTerminal executable target (lines 60-64)**

Remove:
```swift
        .executableTarget(
            name: "GridTerminal",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/GridTerminal"
        ),
```

### grid-server/Sources/GridTerminal/ (DELETE)

Delete the entire directory:
```
rm -rf grid-server/Sources/GridTerminal/
```

This contains only `main.swift` -- the SwiftTerm-based terminal that has been replaced.

## Verification

After all edits:
1. `cd grid-server && swift build` should succeed (no references to GridTerminal remain)
2. `make dev` should succeed (no `terminal` target dependency)
3. `swift package resolve` should NOT fetch SwiftTerm

## Design Notes

This phase is pure cleanup -- no new design decisions. All changes are deletions of dead code and references. The SwiftTerm dependency removal was not in the original plan but is necessary to avoid fetching an unused package.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (N/A -- deletions only)
- [x] Ready for implementation
