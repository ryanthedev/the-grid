# Pseudocode: Phase 4 - CLI RPC + Cleanup

## Files to Create/Modify

### Files to modify:
1. `grid-server/Sources/GridServer/Picker/PickerManager.swift` -- add `showForRPC()` method
2. `grid-server/Sources/GridServer/MessageHandler.swift` -- add `pick.show` handler
3. `grid-server/Sources/GridServer/main.swift` -- add grid-picker daemon kill
4. `grid-server/Package.swift` -- remove GridPicker target
5. `grid-cli/cmd/grid/main.go` -- replace pick commands with RPC-only, remove all picker orchestration
6. `grid-cli/internal/config/types.go` -- remove PickerPath field
7. `grid-cli/internal/config/config.go` -- remove PickerPath expansion
8. `grid-cli/internal/config/config_test.go` -- remove PickerPath test
9. `Makefile` -- remove all grid-picker references

### Files to delete:
1. `grid-server/Sources/GridPicker/main.swift` (entire directory)
2. `grid-cli/internal/sources/` (entire directory -- 9 files)
3. `grid-cli/internal/state/picker_history.go`
4. `grid-cli/internal/state/picker_history_test.go`
5. `grid-cli/cmd/grid/picker_test.go`

### Files NOT deleted (plan correction):
- `grid-cli/internal/enrichers/` -- KEEP, used by `edit` command

## Design: pick.show RPC + Continuation

### Approaches Considered
1. **Stored continuation** -- Add optional `CheckedContinuation` to PickerManager. `showForRPC()` stores it, `handleResult()` checks and resumes it (skipping action execution). BFD path unchanged (continuation is nil).
2. **Callback override** -- `showForRPC()` temporarily replaces `onResult` callback with one that resumes a continuation. Must restore original callback after.
3. **AsyncStream** -- PickerManager publishes results to a stream. RPC handler subscribes and awaits next value.

### Comparison
| Criterion | Stored continuation | Callback override | AsyncStream |
|-----------|-------------------|------------------|-------------|
| Interface simplicity | One new method, one new field | One new method, callback juggling | New stream property, subscription |
| Information hiding | Continuation detail hidden in manager | Callback swap is visible | Stream exposed to callers |
| Caller ease of use | `let result = await manager.showForRPC()` | Same | Must manage stream lifecycle |
| Race safety | Single continuation, cleared after use | Must handle concurrent show/hide | Over-built for single use |

### Choice: Stored continuation (Approach 1)
Rationale: Simplest interface (one new method, one new field). The continuation is an internal detail of PickerManager. BFD callers are unaffected. The only sacrifice is a minor increase in handleResult complexity (one `if` check).

### Depth Check
- Interface methods added: 1 (`showForRPC() async -> PickerResult`)
- Hidden details: continuation storage, thread coordination, action-skip logic
- Common case complexity: simple -- RPC handler calls one method, gets result

## Pseudocode

### PickerManager.swift (modifications)

```
Add a private optional continuation field:
  pendingRPCContinuation: CheckedContinuation<PickerResult, Never>? = nil

Add public async method showForRPC:
  Assert we are on main thread

  If already visible:
    // Another show is in progress (possibly from BFD)
    // Cancel it and return cancelled
    hide()

  Use withCheckedContinuation to:
    Store the continuation in pendingRPCContinuation
    Call show() (which starts discovery, shows window)

  The continuation will be resumed by handleResult
  Return the result

Modify handleResult:
  (existing) Hide first

  Check if pendingRPCContinuation is non-nil:
    If yes:
      Resume the continuation with the result
      Clear pendingRPCContinuation to nil
      Do NOT execute action -- the RPC caller gets the result,
      server does not act on it
      (Note: For RPC callers, the server just reports what was selected.
       The CLI could execute the action, but actually the server should
       still execute the action since it has all the handlers.)

      CORRECTION: The server SHOULD still execute the action even for RPC.
      The picker is now server-owned. The RPC is just a trigger mechanism.
      The server handles the action, then returns the result to the CLI
      for informational purposes.

      So: execute action first (same as BFD path), THEN resume continuation.
      Return after resuming.

    If no (normal BFD path):
      Execute action as before (no change)

Modify hide():
  (existing behavior)
  Additionally: if pendingRPCContinuation is non-nil, resume it with .cancelled
  Clear pendingRPCContinuation
  (This handles the case where the user presses Esc or window loses focus
   during an RPC-triggered show)
```

### MessageHandler.swift (add pick.show handler)

```
In registerBuiltInHandlers(), add:

Register method "pick.show":
  The handler receives (request, completion)

  Launch a Task to handle async work:
    Use MainActor.run to call PickerManager on main thread:
      let result = await PickerManager.shared.showForRPC()

    Build response based on result:
      case .selected(let item):
        Encode item as JSON-compatible dictionary
        Return Response with result: {
          "cancelled": false,
          "selected": {
            "id": item.id,
            "title": item.title,
            "subtitle": item.subtitle,
            "metadata": item.metadata
          }
        }
      case .cancelled:
        Return Response with result: {
          "cancelled": true
        }

    Call completion(response)
```

### main.swift (add grid-picker kill)

```
After the existing grid-terminal kill block (line 50):

  Kill any stale grid-picker from previous sessions:
    Create Process with /usr/bin/pkill
    Arguments: ["-9", "-f", "grid-picker"]
    Try to run, ignore errors
    Wait until exit
```

### Package.swift (remove GridPicker)

```
Remove from products array:
  .executable(name: "grid-picker", targets: ["GridPicker"])

Remove from targets array:
  .executableTarget(name: "GridPicker", dependencies: [], path: "Sources/GridPicker")
```

### main.go (replace pick commands with RPC-only)

```
Remove ALL of the following functions:
  - findPickerExecutable
  - pickerSocketPath
  - tryPickerSocket
  - spawnPickerDaemon
  - waitForPickerSocket
  - launchPicker
  - windowsToPickerItems
  - normalizeTitle
  - hash4
  - stableWindowID
  - sortItemsByHistory
  - runPickWindow
  - runUnifiedPick (replace with new implementation)
  - resolveEnabledSources
  - discoverWindowsAsSourceItems
  - convertSourceItemsToPickerItems
  - parseActionFromMetadata
  - handleWindowFocus
  - handleOpenDir

Remove types:
  - PickerItem
  - PickerResult
  - PickerContext

Remove pickWindowCmd variable and its registration in init()

Remove from init():
  pickCmd.AddCommand(pickWindowCmd)
  pickCmd.Flags().StringSlice("only", ...)
  pickCmd.Flags().StringSlice("exclude", ...)

Remove from shouldSkipMutex:
  "thegrid pick window"

Replace pickCmd definition:
  pickCmd = &cobra.Command{
    Use:   "pick",
    Short: "Open the unified picker",
    Long:  "Triggers the picker UI via the server.
            The server shows the picker window, user selects,
            server executes the action.",
    RunE:  runPick,
  }

New runPick function:
  Create RPC client
  Defer close

  Call client.CallMethod(ctx, "pick.show", nil)
  If error:
    Return formatted error

  Read "cancelled" from result
  If cancelled:
    Return nil (silent exit)

  If "selected" exists in result:
    Print selected item info (id, title) for scripting

  Return nil

Remove imports that become unused:
  - "crypto/sha256"
  - "encoding/hex"
  - "net"
  - "regexp"
  - "sort" (check if used elsewhere first)
  - "github.com/ryanthedev/grid-cli/internal/sources"

Keep imports:
  - "github.com/ryanthedev/grid-cli/internal/enrichers" (used by edit command)
  - "github.com/ryanthedev/grid-cli/internal/state" (used by many non-picker commands)
```

### config/types.go

```
Remove from Settings struct:
  PickerPath string `yaml:"pickerPath,omitempty" json:"pickerPath,omitempty"`
```

### config/config.go

```
Remove from ExpandPaths():
  c.Settings.PickerPath = ExpandTilde(c.Settings.PickerPath)
```

### config/config_test.go

```
Remove PickerPath from test config:
  PickerPath: "~/bin/picker",

Remove PickerPath assertion:
  if cfg.Settings.PickerPath != filepath.Join(home, "bin/picker") { ... }
```

### Makefile

```
Remove from .PHONY:
  picker-universal

Remove targets:
  picker: (lines 39-41)
  picker-universal: (lines 131-140)

Remove from dev dependency list:
  "dev: server cli picker terminal viewer" -> "dev: server cli terminal viewer"

Remove from install-dev:
  cp grid-server/.build/debug/grid-picker ~/.local/bin/grid-picker
  echo for grid-picker

Remove from dist-universal dependency:
  picker-universal

Remove from dist-universal body:
  cp grid-server/.build/apple/Products/Release/grid-picker ...
  file dist/.../bin/grid-picker
```

### Delete files

```
Delete entire directory:
  grid-server/Sources/GridPicker/
  grid-cli/internal/sources/

Delete individual files:
  grid-cli/internal/state/picker_history.go
  grid-cli/internal/state/picker_history_test.go
  grid-cli/cmd/grid/picker_test.go
```

## Design Notes

### Action execution stays server-side
When `pick.show` is called via RPC, the server still executes the action (focus window, open app, etc.). The RPC response is informational -- it tells the CLI what was selected so it can print for scripting. This is correct because:
1. The server has all the action handlers (ActionExecutor, WindowManipulator)
2. The CLI no longer has the source/enricher infrastructure to execute actions
3. Consistency: BFD and RPC paths use the same execution flow

### Enrichers package kept
The plan originally called for removing `grid-cli/internal/enrichers/` but the `edit` command uses `enrichers.NewRegistry()` for window title enrichment during layout editing. This package MUST be kept.

### Sources package fully removed
The `sources` package is ONLY used by picker orchestration in main.go (confirmed: no other files import it). Safe to delete entirely.

### PickerHistory in Go state package
The `picker_history.go` file in `grid-cli/internal/state/` is only used by picker code in main.go. The rest of the state package (LoadState, persistence, queries) is used throughout. Only picker_history.go and its test are deleted.

### Config cleanup
`Settings.PickerPath` becomes dead code. Remove the field, its path expansion, and its test. The `PickerConfig` struct (sources config, actions) stays -- it may still be useful for future config features, and removing it is a separate concern.

### Continuation safety
The `CheckedContinuation` must be resumed exactly once. Three paths:
1. User selects an item -> `handleResult(.selected)` resumes with result
2. User cancels (Esc) -> `handleResult(.cancelled)` resumes with cancelled
3. Window loses focus -> `windowDidResignKey` -> `handleResult(.cancelled)` resumes with cancelled

Edge case: if `hide()` is called directly (e.g., another `show()` call comes in while RPC is waiting), the continuation in `hide()` handles this by resuming with `.cancelled`.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (continuation approach chosen with comparison)
- [x] Plan correction identified (enrichers package must be kept)
- [x] Ready for implementation
