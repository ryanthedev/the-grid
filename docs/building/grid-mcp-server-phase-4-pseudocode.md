# Pseudocode: Phase 4 - Skill + Integration

## DW Verification

| DW-ID | Done-When Item | Status | Pseudocode Section |
|-------|---------------|--------|-------------------|
| DW-4.1 | `~/.claude/skills/thegrid/SKILL.md` exists with tool reference, workflow patterns, interpretation guidance | COVERED | SKILL.md |
| DW-4.2 | MCP server registered in Claude Code settings and starts successfully | COVERED | settings.local.json |
| DW-4.3 | `make mcp-dev` builds and deploys the MCP server binary | COVERED | Makefile targets |
| DW-4.4 | `/thegrid` is listed as an available skill and invocation loads skill context | COVERED | SKILL.md (skill name in frontmatter = `thegrid`) |
| DW-4.5 | End-to-end test: Claude Code uses `grid.layout.list` and gets real data back | COVERED | End-to-end test section |

**All items COVERED:** YES

## Files to Create/Modify
- `~/.claude/skills/thegrid/SKILL.md` — create new
- `~/.claude/settings.local.json` — add mcpServers.thegrid key
- `/Users/r/repos/theGrid/Makefile` — add mcp-dev and mcp-install targets + .PHONY

## Pseudocode

### ~/.claude/skills/thegrid/SKILL.md [DW-4.1, DW-4.4]

```
---
name: thegrid
description: Control theGrid window manager — screenshots, layouts, focus, window ops, recording. Use when you need to see what's on screen, rearrange windows, or capture demos.
---

# theGrid Window Manager — MCP Tools

[Intro: theGrid is a macOS tiling window manager. MCP tools let you
 query state, move windows, apply layouts, capture screenshots, and record demos.]

## When to Use Screenshots vs Queries
- Use grid.screenshot when you need to SEE what's on screen (visual verification,
  checking UI state, confirming window positions)
- Use grid.state.show / dump / grid.layout.current when you need DATA
  (structured window/cell info, script-friendly output)
- Use display.list first to know display count before screenshotting a specific display

## Tool Reference

### Grid Commands (grid.*)

Focus:
- grid.focus(direction) — move keyboard focus left/right/up/down
- grid.focus.cycle([forward]) — cycle through all visible windows
- grid.focus.cell(cell) — focus a specific cell by ID

Layout:
- grid.layout.list — list all available layout IDs [read-only]
- grid.layout.current — get active layout and space ID [read-only]
- grid.layout.get(layout) — get full layout definition [read-only]
- grid.layout.apply(layout, [strategy]) — apply layout to active space
- grid.layout.cycle — advance to next layout in cycle list
- grid.layout.refresh([display]) — reapply current layout, snap windows to cells

Cell:
- grid.cell.send(direction) — move focused window to adjacent cell
- grid.cell.mode([mode]) — set or cycle stack mode (vertical/horizontal/tabs)

Window movement:
- grid.window.move(direction, [wrap], [extend]) — move window to adjacent cell
- grid.window.swap(direction) — swap focused window with neighbor

Resize:
- grid.resize.grow([amount]) — grow split ratio (default 0.1)
- grid.resize.shrink([amount]) — shrink split ratio (default 0.1)
- grid.resize.cell(direction, [amount]) — adjust cell boundary
- grid.resize.reset([cell], [all]) — reset splits to equal

Recording:
- grid.record.start([target], [format], [fps], [duration], ...) — start recording
- grid.record.stop — stop recording, returns output file path
- grid.record.toggle — start if idle, stop if recording

State & Config:
- grid.state.show — full grid state: cells, windows per space [read-only]
- grid.state.reset — clear all grid state for active space (destructive)
- grid.config.show — layout config summary [read-only]

Screenshot:
- grid.screenshot([target], [id], [cursor], [display]) — capture screen as inline image
  - target: 'full' (default), 'window' (needs id=windowID), 'cell' (needs id=cellID)
  - Returns base64 PNG as MCP image content — Claude can view it directly

Utility:
- grid.terminal — toggle the grid terminal overlay

### Window Commands (window.*)

- window.find(query, [app], [title], [exact]) — find windows matching criteria
- window.focus(wid) — focus a window by ID
- window.close(wid) — close a window
- window.raise(wid) — raise window to front without focusing
- window.minimize(wid) / window.unminimize(wid) — minimize/restore
- window.show(wid) / window.hide(wid) — show/hide without minimizing
- window.setOpacity(wid, opacity) / window.getOpacity(wid) — opacity 0.0–1.0
- window.fadeOpacity(wid, opacity, [duration]) — animated opacity change
- window.setLayer(wid, layer) / window.getLayer(wid) — window layer
- window.setSticky(wid, sticky) / window.isSticky(wid) — sticky (all-spaces)

### Query Commands

- ping — verify server is alive
- getServerInfo — server version and uptime
- metadata.get(wid) — detailed window metadata (bounds, app, title, layer, sticky)
- display.list — list all displays with UUIDs and frame rects [read-only]
- display.get(uuid) — get a specific display's info
- dump — full window/display/space snapshot [read-only]
- space.focus(spaceId) — switch to a space
- mouse.warp(x, y) — move mouse cursor to coordinates
- pick.show — show the window picker overlay

## Interpreting Layout / Cell / Window Data

### grid.layout.list output
Returns an array of layout IDs like ["tall-wide", "even-3col", "focus-left"].
Use grid.layout.get(layout) to see the grid structure (rows, cols, cell positions).

### grid.state.show output
```json
{
  "state": {
    "spaces": {
      "<spaceID>": {
        "layout": "tall-wide",
        "cells": {
          "left": { "lastFocusedWid": 1234, "windows": [1234, 5678] },
          "right": { "lastFocusedWid": 5678, "windows": [5678] }
        }
      }
    }
  }
}
```
Cell IDs come from the layout definition (grid.layout.get). Use lastFocusedWid
to identify which window is "in" a cell for screenshot purposes.

### dump output
Returns the raw AX/CGWindow dump — includes all windows with their bounds,
app bundle IDs, and space assignments. Useful for finding windows by app name
when window.find doesn't narrow enough.

### window.find output
Returns array of { wid, app, title, bounds } objects. The wid field is the
numeric window ID to pass to window.focus, metadata.get, grid.screenshot, etc.

## Common Workflows

### See what's on screen
1. grid.screenshot() — full-screen view
2. If you need structured data: grid.state.show + grid.layout.current

### Rearrange windows
1. grid.layout.list — pick a layout
2. grid.layout.apply(layout) — apply it
3. grid.layout.refresh — snap any stray windows
4. grid.screenshot() — confirm result

### Find and focus a specific window
1. window.find(query="Terminal") — get wid
2. window.focus(wid) — bring it forward
3. Or: grid.focus.cell(cell) if you know the cell

### Capture a demo GIF
1. grid.record.start(target="screen", format="gif", fps=15) — start
2. [perform the demo actions]
3. grid.record.stop — returns output file path

### Debug window placement
1. dump — get all windows with bounds
2. grid.state.show — get cell assignments
3. metadata.get(wid) — detailed info for a specific window

## Notes
- grid-server must be running. Use ping to check.
- Cell IDs are layout-specific strings (e.g. "left", "right", "main", "top").
  Get valid IDs from grid.layout.get(layout).
- Window IDs (wid) are uint32 CGWindow IDs. Find them via window.find or dump.
- Recordings write to ~/Desktop/ by default (format: thegrid-YYYY-MM-DD-HH-mm-ss.gif).
```

### ~/.claude/settings.local.json [DW-4.2]

Read existing file first (has permissions block only).
Merge in mcpServers key without disturbing existing content:

```json
{
  "permissions": {
    "allow": [ ...existing... ]
  },
  "mcpServers": {
    "thegrid": {
      "command": "/Users/r/repos/theGrid/grid-mcp/.build/debug/GridMCP",
      "args": []
    }
  }
}
```

### Makefile targets [DW-4.3]

Add to .PHONY line: mcp-dev mcp-install

Add targets after notify-dev section:

```makefile
MCP_BINARY := grid-mcp/.build/debug/GridMCP
MCP_INSTALL_PATH := $(HOME)/.local/bin/grid-mcp

# Build grid-mcp debug binary
mcp:
	cd grid-mcp && swift build
	@echo "✓ GridMCP built"

# Build and symlink grid-mcp binary for dev use
mcp-dev: mcp
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/$(MCP_BINARY) $(MCP_INSTALL_PATH)
	@echo "✓ GridMCP symlinked to $(MCP_INSTALL_PATH)"

# Install grid-mcp binary (copy)
mcp-install: mcp
	@mkdir -p $(HOME)/.local/bin
	@cp $(CURDIR)/$(MCP_BINARY) $(MCP_INSTALL_PATH)
	@echo "✓ GridMCP installed to $(MCP_INSTALL_PATH)"
```

## Design Notes
- settings.local.json uses absolute path to the debug binary — matches how Phase 1 was set up and what already exists at that path
- mcp-dev symlinks (not copies) so re-builds are immediately reflected without re-running mcp-dev
- The SKILL.md skill name `thegrid` matches the plan requirement that `/thegrid` invokes it
- No code changes to grid-mcp package — Phase 4 is config/docs only
