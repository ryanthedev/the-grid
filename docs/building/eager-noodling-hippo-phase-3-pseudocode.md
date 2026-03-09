# Pseudocode: Phase 3 - CLI Subcommand

## Files to Create/Modify
- `grid-server/Sources/GridCLI/TerminalCommand.swift` (new)
- `grid-server/Sources/GridCLI/GridCLI.swift` (add to subcommands)

## Pseudocode

### TerminalCommand.swift

```
TerminalCommand is a ParsableCommand struct

Configuration:
  command name is "terminal"
  abstract is "Toggle the terminal"

Options:
  globals from GlobalOptions (provides socket, json, timeout)

run():
  Create RPC client from globals
  Ensure client disconnects when done

  Call "grid.terminal" on the server (no params)

  If json mode, print result as JSON
  Otherwise print "ok"
```

### GridCLI.swift

```
Add TerminalCommand.self to the subcommands array
  Place after PickCommand.self (last entry, alphabetical not required)
```

## Design Notes

This is pure pattern-following. Every CLI command in GridCLI follows the identical structure:
1. `struct XCommand: ParsableCommand` with configuration
2. `@OptionGroup var globals: GlobalOptions`
3. `run()` creates client, calls RPC method, handles response

TerminalCommand is the simplest possible variant -- no parameters, no meaningful response data. The `printOkOrJSON` helper function (GridCLI.swift:50) is the exact fit for this use case.

No design-it-twice needed: the interface is dictated by the existing pattern and ArgumentParser framework. There is one correct approach.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (trivial pattern-following, no decisions)
- [x] Ready for implementation
