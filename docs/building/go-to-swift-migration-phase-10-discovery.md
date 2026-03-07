# Discovery: Phase 10 - Thin Swift CLI

## Files Found
- `grid-server/Package.swift` -- exists, already has `ArgumentParser` dependency
- `grid-server/Sources/GridServer/MessageHandler.swift` -- has all `grid.*` RPC handlers registered (Phase 9 complete)
- `grid-cli/cmd/grid/main.go` -- ~4200 lines, full Go CLI with all commands
- `grid-cli/internal/client/connection.go` -- Go Unix socket client (newline-delimited JSON-RPC)
- `grid-cli/internal/client/client.go` -- Go client wrapper with `request()`, `CallMethod()`
- `grid-cli/internal/models/envelope.go` -- `MessageEnvelope` with `type`, `request`, `response`, `event` fields
- `grid-server/Sources/GridCLI/` -- does NOT exist (needs creation)

## Current State

### Package.swift
- Already depends on `swift-argument-parser` (1.3.0+)
- Three executable targets: `GridServer`, `GridTerminal`, `GridViewer`
- Need to add `GridCLI` target

### Server RPC Endpoints (Phase 9 -- complete)
All `grid.*` RPCs are registered in `MessageHandler.swift`:
- **Focus:** `grid.focus`, `grid.focus.cycle`, `grid.focus.cell`
- **Layout:** `grid.layout.apply`, `grid.layout.refresh`, `grid.layout.cycle`, `grid.layout.current`, `grid.layout.list`, `grid.layout.get`, `grid.layout.update` (stub), `grid.layout.save` (stub)
- **Cell:** `grid.cell.send`, `grid.cell.mode`
- **Window:** `grid.window.move`, `grid.window.swap`
- **Resize:** `grid.resize.adjust`, `grid.resize.cell`, `grid.resize.reset`
- **State:** `grid.state.show`, `grid.state.reset`
- **Config:** `grid.config.show`
- **Record:** `grid.record.start` (stub until Phase 11)
- **Pre-existing:** `ping`, `pick.show`

### Go CLI Command Structure
The Go CLI has a deep command tree. For the thin Swift CLI, most commands just need to send an RPC and print the result. The key commands per the plan:
- `focus left|right|up|down` -- flags: `--wrap`, `--extend`, `--mouse`
- `focus next|prev` -- flag: `--mouse`
- `focus cell <id>` -- flag: `--space`
- `layout apply <id>` -- flag: `--strategy`
- `layout list`, `layout current`, `layout refresh`, `layout cycle`
- `layout edit` -- special: get layout YAML -> `$EDITOR` -> update RPC
- `cell send <direction>`, `cell mode [mode]`
- `window move left|right|up|down` -- flags: `--wrap`, `--extend`
- `window swap left|right|up|down`
- `resize grow|shrink [amount]` -- flag: `--cell`, `--direction`
- `resize reset` -- flags: `--all`, `--cells`
- `resize cell <direction> [amount]`
- `state show`, `state reset`
- `config show`, `config init`
- `record [target] [id]` -- many flags
- `ping`
- `pick`

### JSON-RPC Wire Format
The protocol is newline-delimited JSON envelopes:
```json
{"type":"request","request":{"id":"uuid","method":"ping","params":{}}}
{"type":"response","response":{"id":"uuid","result":{"timestamp":1234}}}
```

### Socket Path
Default: `/tmp/grid-server.sock`

## Gaps

1. **`grid.layout.update` is a stub** -- returns "not yet implemented". The `layout edit` command needs this. Plan says to implement it but this is a server-side gap (Phase 9 concern). The CLI should still implement the `edit` workflow and fail gracefully with the server error.
2. **`grid.layout.save` is also a stub** -- same situation.
3. **No `grid.record.start` implementation** -- stub until Phase 11. CLI should wire it up to print the error.
4. **`grid.layout.get` returns structured JSON, not YAML** -- The Go `layout edit` opens YAML in `$EDITOR`. The Swift CLI `layout edit` can use JSON or YAML. Since server returns JSON dict of layout def, CLI will need to serialize it to YAML for editing (or JSON). JSON is simpler and avoids a Yams dependency in the CLI.
5. **Commands NOT in plan scope** -- `terminal`, `view`, `render`, `show`, `list`, `dump`, `info`, `debug`, `window get/find/update`, `space`, `event`, `mouse` -- these are either dropped per plan or remain Go-only until Phase 12 deletes Go CLI.

## Prerequisites
- [x] Phase 9 complete (RPC handlers registered)
- [x] `ArgumentParser` already in Package.swift dependencies
- [x] Wire format understood (MessageEnvelope)
- [x] All RPC method names and params documented
- [x] Socket path default known (`/tmp/grid-server.sock`)

## Recommendation
**BUILD** -- All prerequisites met. Create `GridCLI` target with RPC client and command files.
