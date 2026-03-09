# Discovery: Phase 12 - Delete Go CLI + Update Build

## Files Found

### To Delete
- `grid-cli/` — entire directory (Go CLI codebase: cmd/, internal/, Makefile, go.mod, go.sum, bin/, etc.)

### To Modify
- `Makefile` — root Makefile with Go CLI targets throughout
- `~/.config/thegrid/bfd.yaml` — hotkey config using `$grid` (Go CLI) for all commands
- `grid-server/Sources/GridServer/main.swift` — add stale mutex file cleanup
- `scripts/reapply-layouts.sh` — references `$REPO_DIR/grid-cli/bin/thegrid` and uses Go CLI commands (`dump --json`, `layout current --space`)

### Already Complete (No Changes Needed)
- `grid-server/Package.swift` — already has `GridCLI` target at `Sources/GridCLI/`
- `grid-server/Sources/GridCLI/` — 12 Swift CLI source files already exist
- `grid-server/Sources/GridServer/BFD/BFDManager.swift` — already routes `@` commands through `GridCommandRouter`

## Current State

The Swift CLI (`GridCLI`) is fully implemented (Phase 10). The `GridCommandRouter` handles `@` commands in-process (Phase 8). All grid operations are server-side (Phases 1-9, 11). The Go CLI is completely redundant.

### Makefile Go References (lines to change)
- `cli:` target (line 56-58) — calls `cd grid-cli && $(MAKE) build`
- `cli-test:` (line 60-62) — calls `cd grid-cli && $(MAKE) test`
- `cli-clean:` (line 64-66) — calls `cd grid-cli && $(MAKE) clean`
- `cli-install:` (line 68-70) — calls `cd grid-cli && $(MAKE) install`
- `test:` (line 73) — depends on `cli-test`
- `clean:` (line 76) — depends on `cli-clean`
- `dist:` (line 84,89) — references `grid-cli/bin/thegrid`
- `cli-universal:` (line 111-124) — Go cross-compile for universal binary
- `dist-universal:` (line 156,161) — references `grid-cli/bin/thegrid`
- `dev:` (line 222) — depends on `cli`
- `install-dev:` (line 251-253) — copies `grid-cli/bin/thegrid`
- Help text (lines 203-207) — mentions grid-cli
- `tail-cli:` (line 270-271) — tails CLI log (can remove, Swift CLI logs to server log)

### BFD Config — All `$grid` References
Every hotkey currently spawns `$grid` (Go CLI process). All need to become `@` commands:
- Navigation: `$grid focus prev/next/left/right/up/down`
- Movement: `$grid window move left/right/up/down`
- Swap: `$grid window swap left/right/up/down`
- Resize: `$grid resize cell/grow/shrink/reset`
- Layout: `$grid layout refresh/apply`
- Cell mode: `$grid cell mode`
- Terminal: `$grid terminal` — NO `@terminal` command exists yet

### Go CLI Mutex File
- Lock file: `~/.local/state/thegrid/cli.lock` (from `mutex.go`)
- Server should clean this up on startup since no Go CLI will be creating it anymore

## Gaps

1. **`$grid terminal` has no `@` equivalent.** The Go CLI `terminal` command sends a distributed notification to toggle the terminal. There is no `@terminal` command in `GridCommandRouter` and no `terminal` domain handler. The terminal toggle needs to become an `@` command or the BFD hotkey needs an alternative approach.

2. **`scripts/reapply-layouts.sh` uses Go CLI.** It calls `$THEGRID dump --json` and `$THEGRID layout current --space`. This script needs to either be rewritten to use the Swift CLI or replaced with an `@layout refresh` command (which already exists in GridCommandRouter).

3. **`alt-a: thegrid-reapply-layouts`** in BFD config calls the shell script above. Should become `@layout refresh`.

4. **`cmd-9: rm /Users/r/.local/state/thegrid/thegrid*`** — hardcoded path in BFD config. Not a Go CLI issue but worth noting.

5. **No `tail-cli` equivalent needed.** Swift CLI is thin — it just sends RPCs. Server logs capture everything.

## Prerequisites
- [x] Swift CLI exists and is functional (Phase 10 complete)
- [x] GridCommandRouter handles @ commands (Phase 8 complete)
- [x] All grid operations are server-side (Phases 1-7 complete)
- [x] RPC handlers exist for CLI access (Phase 9 complete)
- [ ] Terminal toggle needs @ command (gap — see above)

## Recommendation
**BUILD** — with the caveat that terminal toggle needs a simple `@terminal` addition to GridCommandRouter (or inline handling in BFDManager since it already has terminal kill logic in main.swift). This is a small addition, not a blocker.
