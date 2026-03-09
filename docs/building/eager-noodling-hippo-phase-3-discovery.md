# Discovery: Phase 3 - CLI Subcommand

## Files Found
- `grid-server/Sources/GridCLI/GridCLI.swift` - Main CLI entry, subcommand registration, GlobalOptions, helper functions
- `grid-server/Sources/GridCLI/PickCommand.swift` - Reference pattern (simplest command with response handling)
- `grid-server/Sources/GridCLI/PingCommand.swift` - Reference pattern (simplest fire-and-forget style)
- `grid-server/Sources/GridCLI/RPCClient.swift` - RPC client, `call()` returns `[String: Any]`
- `grid-server/Sources/GridServer/MessageHandler.swift` - `grid.terminal` RPC already registered (Phase 2 complete)

## Current State
- **TerminalCommand.swift does NOT exist** - needs to be created
- **GridCLI.swift subcommands array** has 10 entries (Ping through Pick), no TerminalCommand
- **Server-side `grid.terminal` RPC is registered** (confirmed at MessageHandler.swift:1796)
- **Pattern is clear:** All commands are `struct XCommand: ParsableCommand` with `@OptionGroup var globals: GlobalOptions`, `makeClient(from:)`, `defer { client.disconnect() }`, `client.call("method")`
- **Terminal command needs no response handling** - it's a toggle with no meaningful return data. Closest pattern is PingCommand but even simpler (no elapsed time tracking). Just call and print "ok" or JSON result.

## Gaps
- None. The plan accurately describes what exists and what needs to be built.

## Prerequisites
- [x] PickCommand.swift exists as reference pattern
- [x] GridCLI.swift exists with subcommands array to extend
- [x] RPCClient with `call()` method available
- [x] Server-side `grid.terminal` RPC registered (Phase 2)
- [x] GlobalOptions type available (socket, json, timeout)

## Recommendation
BUILD - Create TerminalCommand.swift and register in GridCLI.swift subcommands. Straightforward pattern-following, no design decisions needed.
