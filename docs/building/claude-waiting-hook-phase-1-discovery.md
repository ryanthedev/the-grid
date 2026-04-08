# Discovery: Phase 1 - Window lookup by PID

## Files Found

### Server
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/MessageHandler.swift` — exists, contains `window.find` handler (lines 223-257)
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/Picker/Enrichment/ProcessTree.swift` — exists, builds `children[ppid]->[pid]` map, has `getDescendants(of:maxDepth:)` method
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/StateModels.swift` — `WindowState.pid: pid_t` confirmed (line 175)
- `/Users/r/repos/theGrid/grid-server/Sources/GridServer/StateManager.swift` — exists (state access pattern)

### CLI
- `/Users/r/repos/theGrid/grid-server/Sources/GridCLI/WindowCommand.swift` — exists, subcommands: `move`, `swap`. No `find` subcommand.
- `/Users/r/repos/theGrid/grid-server/Sources/GridCLI/GridCLI.swift` — `WindowCommand` is registered

### Tests
- `/Users/r/repos/theGrid/grid-server/Tests/GridServerTests/` — test target exists

## Current State

### `window.find` RPC handler (exists, partial)
The handler currently accepts `appName` (String) and `title` (String) filter params and returns the first matching window. It already includes `pid` in the response payload but does NOT accept `pid` as an input search parameter. It does not perform any process-tree ancestor walk.

### `ProcessTree` (exists, downward only)
`ProcessTree` builds a parent→children map from `ps -eo pid,ppid`. Its only public traversal method is `getDescendants(of:maxDepth:)` which walks *downward* (parent → children). There is no upward traversal (child → ancestor chain) method.

The plan requires the *inverse*: given a PID passed in via CLI (e.g., Claude Code's PID), walk *up* the process tree to find a PID that matches a known window's `pid` field.

### `WindowCommand` CLI (exists, missing `find`)
Only `window move` and `window swap` subcommands exist. `window find --pid <PID>` does not exist.

## Gaps

1. `window.find` RPC handler does not accept a `pid` param for process-tree-based lookup.
2. `ProcessTree` has no upward/ancestor traversal method — needs `getAncestors(of:)` or a parent-map lookup.
3. `WindowCommand` CLI has no `find` subcommand.

## Approach Design Notes

Two server-side design approaches for PID lookup:

**Approach A — Ancestor walk in server handler**
Build `ProcessTree`, for each known window collect all descendant PIDs (downward), check if input PID is in any window's descendants. Reuses existing `getDescendants`.

**Approach B — Parent map in ProcessTree, walk upward**
Add a `parent[pid] -> ppid` map to `ProcessTree`. Given input PID, walk up the chain until a matching window PID is found. More efficient for deep chains, simpler logic per window.

Approach B is cleaner: O(depth) vs O(windows × descendants). Add `getAncestors(of:maxDepth:) -> [pid_t]` to `ProcessTree`, then in the handler check if any window PID appears in that ancestor list.

## Prerequisites

- [x] `window.find` RPC handler exists to extend
- [x] `ProcessTree` exists and can be extended
- [x] `WindowState.pid` field available for matching
- [x] CLI command pattern established (ArgumentParser, RPCClient)
- [x] Test target exists
- [x] `StateManager.shared.getState()` async pattern established

## Recommendation

BUILD — all prerequisites met. No missing dependencies. The work is additive:
1. Add `getAncestors(of:maxDepth:)` to `ProcessTree`
2. Extend `window.find` handler to accept `pid` param and perform ancestor walk
3. Add `WindowFind` subcommand to `WindowCommand` CLI
