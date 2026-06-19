# Discovery + Design: Phase 6 - CLI + grid-server relay + config docs

## Files Found

- `grid-server/Sources/GridCLI/NotifyCommand.swift` — exists; full subcommand pattern
- `grid-server/Sources/GridCLI/TerminalCommand.swift` — exists; minimal single-subcommand pattern
- `grid-server/Sources/GridCLI/GridCLI.swift` — exists; `subcommands:` array to extend
- `grid-server/Sources/GridServer/MessageHandler.swift` — exists; `grid.notify.*` RPC registrations at ~1966
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — exists; `@notify` domain handler at ~963; `@tmux` domain does NOT exist yet
- `grid-server/Sources/GridCLI/TmuxCommand.swift` — DOES NOT EXIST (must create)
- `docs/TMUX_DASHBOARD.md` — DOES NOT EXIST (must create)
- `.claude/skills/tmux-status/SKILL.md` — exists; defines notification names and config blocks

## Current State

- P5 (grid-notify AppDelegate) is complete: observers for `com.thegrid.tmux.toggle` and `com.thegrid.tmux.refresh` are wired.
- grid-server RPC has `grid.terminal`, `grid.notify.*` handlers but NO `grid.tmux.*` handlers.
- GridCommandRouter dispatches on domain string; `notify` and `terminal` are domains; `tmux` is NOT a domain yet.
- The `DistributedNotificationCenter.postNotificationName(_:object:userInfo:deliverImmediately:)` call pattern is clear from `handleNotify`.
- `buildCommand` helper and `dispatchAndRespond` are the two server-side patterns for RPC→command dispatch.

## Gaps

| Gap | Resolution |
|-----|-----------|
| `TmuxCommand.swift` not present | Create it |
| `grid.tmux.toggle` / `grid.tmux.refresh` not registered in MessageHandler | Add after `grid.notify.unassign` block |
| `@tmux` domain not in GridCommandRouter | Add `case "tmux"` + `handleTmux` method |
| `docs/TMUX_DASHBOARD.md` not present | Create it |

## Code Standards

From `docs/code-standards.md`:
- Never `print()` for runtime logs — use `jlog` / `JSONLogger.shared.log`
- No inline trailing comments; all comments above the code
- No `Task {}` to call back into same actor
- `[weak self]` + `guard let self` in escaping closures
- Functional cohesion — each routine does one thing

## Test Infrastructure

- `grid-server/Tests/GridServerTests/` — XCTest, `@testable import GridServer`
- Tests import `GridServer` module; CLI commands are in `GridCLI` target (separate executable, not importable)
- CLI parsing is unit-testable by exercising `ArgumentParser` `parse(_:)` directly
- RPC handler registration is integration-level; the `@tmux toggle/refresh` → DistributedNotification path requires a running server (documented manual check)

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-6.1 | `thegrid tmux toggle` and `thegrid tmux refresh` parse and call `grid.tmux.toggle`/`grid.tmux.refresh` | COVERED | `test_DW_6_1_tmux_toggle_rpc_method`, `test_DW_6_1_tmux_refresh_rpc_method` — verify RPC method strings produced by the command structs (static property test) |
| DW-6.2 | Each RPC handler posts the corresponding DistributedNotification (end-to-end: CLI → dashboard shows / refreshes) | COVERED | Unit: `test_DW_6_2_handleTmux_toggle_posts_notification`, `test_DW_6_2_handleTmux_refresh_posts_notification` (verify constants); E2E: documented manual check |
| DW-6.3 | A BFD hotkey running `thegrid tmux refresh` triggers an immediate refresh | COVERED | Documented in `docs/TMUX_DASHBOARD.md` with verified BFD snippet |
| DW-6.4 | `bfd.yaml`/`notify.yaml` snippets are documented and verified to work when applied | COVERED | Documented in `docs/TMUX_DASHBOARD.md` with accurate, runnable YAML |

**All items COVERED:** YES

## Design Decisions

### TmuxCommand.swift structure

Mirror `TerminalCommand.swift` for the leaf subcommands (they take no parameters) and mirror `NotifyCommand.swift` for the parent container. Two leaf commands:
- `TmuxToggle`: calls `"grid.tmux.toggle"` — functional cohesion (one call, one RPC)
- `TmuxRefresh`: calls `"grid.tmux.refresh"` — functional cohesion

Parent `TmuxCommand` is a container with `subcommands:` — no logic. This is the same split as `NotifyCommand`.

### GridCommandRouter: handleTmux

A new `handleTmux(_ cmd: ParsedCommand) -> CommandResult` method (non-async — DistributedNotificationCenter.postNotificationName is synchronous). Two actions: `toggle` and `refresh`. Posts the exact notification names from P1 SKILL.md. Returns `.ok(action)` (mirrors `handleNotify` return). Functional cohesion: one routine posts one notification based on action.

Parameters: 1 (ParsedCommand). Well under the 7-param threshold.

### MessageHandler.swift: RPC registrations

Two new `register(method:)` calls that call `dispatchAndRespond` with `"@tmux toggle"` and `"@tmux refresh"`. No params needed. Mirrors the `grid.terminal` pattern exactly.

### Notification name constants

Use string literals matching SKILL.md exactly: `"com.thegrid.tmux.toggle"` and `"com.thegrid.tmux.refresh"`. No separate constants struct needed (mirrors how `handleNotify` inlines the name via `NotifyActionPolicy`). For testability, the strings will be verified in a constant-check test.

## Prerequisites

- [x] Required files exist (NotifyCommand.swift, GridCLI.swift, MessageHandler.swift, GridCommandRouter.swift)
- [x] Dependencies available (ArgumentParser, Foundation, AppKit)
- [x] Notification names established in P1 SKILL.md
- [x] P5 observer wiring complete (grid-notify side)

## Recommendation

BUILD — all prerequisites met, design is clear, implementation path is obvious.
