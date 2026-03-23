# Pseudocode: Phase 1 - Window lookup by PID

## Files to Create/Modify

- `grid-server/Sources/GridServer/Picker/Enrichment/ProcessTree.swift` — add `getAncestors(of:maxDepth:)` method
- `grid-server/Sources/GridServer/MessageHandler.swift` — extend `window.find` handler to accept `pid` param
- `grid-server/Sources/GridCLI/WindowCommand.swift` — add `WindowFind` subcommand
- `grid-server/Sources/GridCLI/GridCLI.swift` — no change needed (WindowCommand already registered)

---

## Design

### Design: ProcessTree ancestor traversal

**Approaches considered:**
1. **Add parent map + getAncestors** — store `parent[pid] -> ppid` during build. Walk upward from input PID collecting ancestors. O(depth) per query.
2. **Reuse getDescendants for each window** — for every window PID, collect all descendants, check if input PID is in the set. O(windows × avg_descendants) per query.
3. **Build inverted index once** — precompute `descendantPID -> windowPID` map before the RPC. Same cost as approach 2 but paid once up front.

**Comparison:**

| Criterion | A: parent map + walk up | B: descendants per window | C: inverted index |
|-----------|------------------------|--------------------------|-------------------|
| Interface simplicity | Simple — getAncestors(pid) | No new API needed | Requires new API |
| Traversal cost | O(depth) ~5-10 steps | O(windows × ~50 desc) | O(total processes) once |
| Memory cost | One extra dict (same size as children) | None | Large dict |
| Hidden complexity | Low | Logic in handler | Logic in handler |

**Choice: A (parent map + getAncestors)**
Rationale: The handler needs to find "which window PID is an ancestor of input PID." Walking upward from the input PID is the natural, minimal traversal. Storing a parent map costs one extra dictionary during build — acceptable. Approach B would be correct but puts O(windows) logic in the handler where it doesn't belong.

### Design: window.find PID branch

**Approaches considered:**
1. **New RPC method `window.findByPID`** — separate handler, clean separation.
2. **Extend existing `window.find` with `pid` param** — reuses handler registration, consistent with existing `appName`/`title` params.
3. **New RPC method `window.owner`** — semantic rename, cleaner API surface.

**Comparison:**

| Criterion | A: extend window.find | B: new findByPID | C: new window.owner |
|-----------|-----------------------|-----------------|---------------------|
| CLI consistency | Matches `thegrid window find` | Awkward CLI naming | OK but different domain |
| Handler reuse | High | Low | Low |
| Caller cognitive load | Low (one method) | Medium (two methods) | Medium |
| Information hiding | Same | Same | Same |

**Choice: A (extend window.find)**
Rationale: The plan explicitly states "extend existing `window.find` to accept `pid` param." Single method with multiple filter modes is consistent with `display.get` (accepts `uuid` or `active`). The `pid` branch is mutually exclusive with `appName`/`title` — validated via guard.

---

## Pseudocode

### `ProcessTree.swift` — add `getAncestors` and parent map

```
In ProcessTree class:

Add private field:
    parent: [pid_t: pid_t] = [:]   // pid -> its parent pid

In build() static method, inside the parsing loop where we currently do:
    tree.children[ppid, default: []].append(pid)

Also add:
    tree.parent[pid] = ppid

New public method getAncestors(of targetPID: pid_t, maxDepth: Int) -> [pid_t]:
    If maxDepth <= 0, return empty list

    result = []
    current = targetPID
    steps = 0

    While steps < maxDepth:
        If parent[current] does not exist, break   // reached root or unknown PID
        ppid = parent[current]
        Append ppid to result
        current = ppid
        steps += 1

    Return result
    // Caller checks if any window PID appears in this list
```

### `MessageHandler.swift` — extend `window.find` handler

```
In the window.find handler, after extracting appNameFilter and titleFilter:

Also extract:
    pidFilter = params["pid"]?.value as? Int

Adjust the guard:
    Guard at least one of appNameFilter, titleFilter, or pidFilter is non-nil
    Otherwise return error "At least one of appName, title, or pid required"

In the Task body, before the existing window loop:

If pidFilter is non-nil:
    Build process tree: let tree = await ProcessTree.build()
    Get ancestors of pidFilter up to maxDepth 8:
        let ancestors = tree.getAncestors(of: pid_t(pidFilter), maxDepth: 8)
    Build lookup set: ancestorSet = Set([pid_t(pidFilter)] + ancestors)
    // Includes the PID itself in case it directly owns a window

    For each window in state.windows.values:
        Skip if window.isHidden
        Skip if window.frame.height < 100
        If ancestorSet.contains(window.pid):
            Return response: found=true, windowId=String(window.id), pid=window.pid

    Return response: found=false
    // Return early — pid branch is exclusive

Otherwise (appName/title branch):
    [existing loop unchanged]
```

### `WindowCommand.swift` — add `WindowFind` subcommand

```
Extend WindowCommand.configuration.subcommands to include WindowFind.self

New struct WindowFind: ParsableCommand:
    configuration: commandName="find", abstract="Find window by process ID"

    @Option(name: .long, help: "Process ID to find owning window for")
    var pid: Int

    @OptionGroup var globals: GlobalOptions

    func run() throws:
        client = makeClient(from: globals)
        defer client.disconnect()

        result = try client.call("window.find", params: ["pid": pid])

        If globals.json:
            printResult(result, json: true)
        Else if result["found"] as? Bool == true:
            Print result["windowId"] as? String ?? ""
            // Plain text output: just the window ID, one line
        Else:
            // Exit with error code so callers can detect not-found
            Throw ValidationError("no window found for pid \(pid)")
```

---

## Design Notes

### Why maxDepth 8 for ancestor walk
The typical process chain for a Claude Code session inside tmux inside a terminal is:
`terminal (window owner) -> login shell -> tmux client -> shell -> claude`. That's depth 4-5. Using 8 gives headroom for nested shells, sudo, etc. without unbounded walk to PID 1.

### Why include the PID itself in the ancestor set
If the process directly owns a window (e.g., a GUI app calls `thegrid window find --pid $MY_PID`), it should find itself. Adding the input PID to the ancestor set at zero cost handles this case.

### Why error (not silent empty) on not-found in CLI
The hook script needs to branch on whether a window was found. A non-zero exit code from the CLI is the standard shell idiom for "nothing found." Using `ValidationError` achieves this while printing a human-readable message to stderr.

### Plain text output prints only windowId
The hook script (`thegrid window find --pid $PID`) needs to capture the window ID cleanly for use in a notification action (`focus:<windowId>`). Printing only the ID (no JSON) makes shell assignment trivial: `WID=$(thegrid window find --pid $PID)`. JSON mode is available for callers that need the full response.

### ProcessTree build runs async on DispatchQueue.global()
Consistent with existing `ProcessTree.build()` contract — the handler already runs inside a `Task {}` block, so `await ProcessTree.build()` fits naturally.

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (aposd-designing-deep-modules: 2-3 alternatives compared for both ProcessTree and handler)
- [ ] Ready for implementation
