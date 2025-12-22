# ADR-001: No Auto-Layout on Server Startup

**Date:** 2025-12-22
**Status:** Accepted

## Context

When the grid-server starts, it has no knowledge of the user's intended window layout. The server can detect windows and spaces, but it doesn't know:

- Which layout the user wants applied to each space
- Whether the user even wants a layout applied at all
- What the previous state was before restart

Previously, the server attempted to auto-apply layouts on startup by:
1. Reading CLI state files to check if layouts existed
2. Spawning CLI processes to apply default layouts
3. Triggering layout application on space changes

This approach had timing issues - the server would apply layouts before state was fully populated, causing race conditions and incorrect window assignments.

## Decision

**The server will not auto-apply layouts on startup or space change.**

Layout application is now entirely user-initiated via CLI commands (e.g., `thegrid layout apply`).

## Consequences

### Positive

1. **No jarring window movements on startup** - Windows stay where they are until the user explicitly requests a layout. This aligns with the core project goal: layouts should not cause unexpected window movements.

2. **Predictable behavior** - The user is always in control. No surprises from the server making autonomous decisions about window placement.

3. **Simpler server architecture** - Removed `AutoLayoutManager`, `CLIStateReader`, and associated timing/synchronization complexity.

4. **No race conditions** - Eliminated the timing issues where layouts were applied before state was ready.

### Negative

1. **No borders on startup** - Since borders are tied to cell assignments (which come from layout application), borders won't appear until the user applies a layout. This is a tradeoff we accept.

2. **User must manually apply layouts** - After server restart, the user needs to run `thegrid layout apply` to restore their layout. This could be automated via shell startup scripts if desired.

## Alternatives Considered

### Wait for first focus event
Trigger auto-layout when the first `win.focus` event occurs. Rejected because:
- Still makes autonomous decisions about window placement
- Edge cases when no focus event occurs
- Adds coupling between StateManager and AutoLayoutManager

### CLI-triggered startup layouts
Have the CLI send a "ready" message to trigger layouts. Rejected because:
- Still results in unexpected window movements
- Adds complexity to CLI startup flow

## Notes

Users who want automatic layout restoration can add `thegrid layout apply <layout>` to their shell rc file or use a launchd agent. This keeps the automation explicit and user-controlled.
