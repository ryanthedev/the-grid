# Pseudocode: Phase 12 - Delete Go CLI + Update Build

## Files to Create/Modify

### Delete
- `grid-cli/` (entire directory)

### Modify
- `Makefile`
- `~/.config/thegrid/bfd.yaml`
- `grid-server/Sources/GridServer/main.swift`
- `scripts/reapply-layouts.sh` (delete or rewrite)

## Pseudocode

### 1. Makefile — Remove Go, Wire Swift CLI

The `cli:` target must now build the Swift `GridCLI` product from the grid-server Swift package.

```
cli target:
  Print "Building grid-cli (Swift)..."
  cd grid-server && swift build --product grid-cli

cli-test target:
  REMOVE entirely (Swift CLI has no separate tests; server-test covers it)

cli-clean target:
  REMOVE entirely (server-clean already cleans Swift package)

cli-install target:
  REMOVE entirely (install-dev handles it)

cli-universal target:
  Print "Building grid-cli universal binary..."
  cd grid-server && swift build -c release --product grid-cli --arch arm64 --arch x86_64
  Verify universal binary at grid-server/.build/apple/Products/Release/grid-cli

test target:
  Depends on server-test only (remove cli-test dependency)

clean target:
  Depends on server-clean only (remove cli-clean dependency)

dev target:
  Remove cli dependency (server build already compiles GridCLI)
  Keep: server, terminal, viewer
  After building app bundle, also copy grid-cli binary to app bundle or keep separate

install-dev target:
  Change: copy Swift CLI binary from grid-server/.build/debug/grid-cli to ~/.local/bin/thegrid
  Keep: grid-viewer copy

dist target:
  Change: copy grid-server/.build/release/grid-cli instead of grid-cli/bin/thegrid

dist-universal target:
  Change: copy grid-server/.build/apple/Products/Release/grid-cli instead of grid-cli/bin/thegrid

help text:
  Update CLI section to say "Swift CLI" instead of grid-cli
  Remove cli-test, cli-clean, cli-install from help
  Remove tail-cli from help

tail-cli target:
  REMOVE entirely (Swift CLI logs go to server log)

PHONY line:
  Remove cli-test, cli-clean, cli-universal references
  Add grid-cli-related Swift targets if needed
```

### 2. BFD Config (`bfd.yaml`) — Convert to @ Commands

```
REMOVE vars section entirely (no more $grid variable needed)

Convert hotkeys section:

  # Navigation — $grid focus X becomes @focus X
  cmd-h: "@focus prev -m"
  cmd-l: "@focus next -m"
  cmd+shift-h: "@focus left --extend --mouse"
  cmd+shift-l: "@focus right --extend -m"
  cmd+shift-j: "@focus down --extend -m"
  cmd+shift-k: "@focus up --extend -m"

  # Movement — $grid window move X becomes @window move X
  cmd+ctrl-h: "@window move left --extend -m"
  cmd+ctrl-l: "@window move right --extend -m"
  cmd+ctrl-j: "@window move down --extend -m"
  cmd+ctrl-k: "@window move up --extend -m"

  # Swap — $grid window swap X becomes @window swap X
  ctrl+alt-h: "@window swap left -m"
  ctrl+alt-l: "@window swap right -m"
  ctrl+alt-j: "@window swap down -m"
  ctrl+alt-k: "@window swap up -m"

  # Resize — $grid resize X becomes @resize X
  cmd+alt-h:
    run: "@resize cell left 0.01"
    rate_limit: 20
  cmd+alt-l:
    run: "@resize cell right 0.01"
    rate_limit: 20
  cmd+alt-j:
    run: "@resize grow 0.01"
    rate_limit: 20
  cmd+alt-k:
    run: "@resize shrink 0.01"
    rate_limit: 20
  cmd+alt-0: "@resize reset --cells"

  # Layout — $grid layout X becomes @layout X
  cmd-0: "@layout refresh"
  cmd-1: "@layout apply single-tabs"
  cmd-2: "@layout apply two-column"
  cmd-3: "@layout apply three-column"

  # Cell mode
  alt-s: "@cell mode"

  # Reapply layouts — was shell script, now @ command
  alt-a: "@layout refresh"

  # Terminal — was $grid terminal, becomes @terminal
  ctrl-backtick:
    run: "@terminal"
    repeat: false

  # Keep unchanged (already @ commands or shell commands):
  cmd-return (open Ghostty) — stays as shell command
  cmd-escape (@pick) — already @ command
  cmd+shift-escape (@test) — already @ command
  cmd-9 (rm logs) — stays as shell command
  alt-escape (services stop) — stays as shell command
```

### 3. main.swift — Remove Stale CLI Mutex File

```
In GridServerCommand.run(), after existing stale process cleanup:

  // Remove stale Go CLI mutex file
  Let stateDir = XDG state directory (~/.local/state/thegrid/)
  Let lockPath = stateDir + "cli.lock"
  If file exists at lockPath:
    Try to delete it
    Log "srv.cleanup" with data: file path removed
```

### 4. Terminal Toggle — Add @terminal Command

The GridCommandRouter needs to handle `@terminal`. The terminal toggle works via NSDistributedNotification.

```
In GridCommandRouter.dispatch():
  When domain is "terminal":
    Post NSDistributedNotification "com.thegrid.terminal.toggle"
    Return success

This is a 3-line addition to the router's switch/dispatch logic.
```

### 5. Delete grid-cli/ Directory

```
rm -rf grid-cli/
```

Single destructive operation. No partial deletion needed.

### 6. scripts/reapply-layouts.sh — Delete

```
rm scripts/reapply-layouts.sh
```

The `@layout refresh` command already handles refreshing all displays.
The `alt-a` hotkey now maps directly to `@layout refresh`.
Also remove the `install-scripts` Makefile target and its symlink.

### 7. Package.swift and README Cleanup

```
grid-server/README.md:
  Remove references to grid-cli directory and Go build instructions
  Update "Use the grid-cli client" text

No Package.swift changes needed — GridCLI target already exists.
```

## Design Notes

**Why `@` commands instead of Swift CLI for hotkeys:**
- Eliminates process spawn per keypress (~50ms saved per hotkey)
- No socket connection overhead
- No config/state reload
- Direct in-process function call via GridCommandRouter

**Terminal toggle approach:**
- Reuse existing NSDistributedNotification pattern from Go CLI
- GridTerminal already listens for "com.thegrid.terminal.toggle"
- Router just posts the notification — simple, no new dependencies

**Mutex cleanup rationale:**
- The `cli.lock` file uses `flock()` which auto-releases on process exit
- But the file itself persists on disk even when unlocked
- Server cleanup is cosmetic but prevents confusion during debugging

**BFD config format:**
- `@` commands must be quoted in YAML since `@` has no special meaning but the whole string is the command
- BFDManager already detects `@` prefix and routes to handleInternalCommand
- Extended format (`run: "@resize cell left 0.01"`) works the same way

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed
- [x] Ready for implementation
