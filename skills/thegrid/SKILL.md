---
name: thegrid
description: Control theGrid window manager and drive the Mac — screenshots, layouts, focus, window ops, mouse/keyboard input, recording. Use when you need to see what's on screen, rearrange windows, click or type into an app, or capture demos.
---

# theGrid — MCP Tools

theGrid is a macOS tiling window manager. Its MCP server (`thegrid mcp serve`) exposes 48 tools over a Unix socket to the running grid-server: query state, move windows, apply layouts, capture screenshots, synthesize mouse and keyboard input, record demos.

## Tool names in Claude Code

Tools appear as `mcp__thegrid__<name>` with dots replaced by underscores: `grid.screenshot` is `mcp__thegrid__grid_screenshot`, `input.mouse.click` is `mcp__thegrid__input_mouse_click`. If the tools are deferred, load the ones you need in ONE call before using them:

```
ToolSearch("select:mcp__thegrid__ping,mcp__thegrid__grid_screenshot,mcp__thegrid__input_mouse_click")
```

## First call: `ping`

Always `ping` first. If it fails, the grid-server is down:

1. `thegrid ping` in Bash confirms it from the CLI side.
2. From the repo, `make run` rebuilds and restarts the dev service; `services restart thegrid-dev` just restarts it.
3. Recent errors: `tail -20 ~/.local/state/thegrid/thegrid-server.json`.

Do not retry tool calls in a loop while the server is down.

## Screenshots vs queries

- `grid.screenshot` when you need to SEE (visual verification, reading UI, choosing where to click). Returns an inline image plus a JSON geometry block.
- `grid.state.show` / `dump` / `grid.layout.current` when you need DATA (window IDs, frames, cell assignments).
- `display.list` first when targeting a display; `display` indexes are 0-based in `display.list` order and the default is the active display.
- `quality="low"` (default, ≤1024px JPEG) is enough to check layout and find controls. Use `quality="high"` (full-res PNG) only when you must read small text.

## Coordinates: screenshot pixels → screen points

All `input.*` coordinates are **global screen points** (top-left origin, multi-display aware; a display above the main one has negative y). They are NOT screenshot pixels: Retina capture is 2× points and the low-quality image is downscaled again.

Every `grid.screenshot` returns, after the image, a text block like:

```json
{"target":"window","windowId":14488,"frame":{"x":500,"y":-1031,"width":656,"height":422},"image":{"width":1024,"height":658}}
```

To click something you see at pixel `(px, py)` in that image:

```
x = frame.x + px * frame.width  / image.width
y = frame.y + py * frame.height / image.height
```

Window and cell captures exclude the shadow, so image edges are window edges. Window frames also come from `dump` (`windows[wid].frame` = `[[x, y], [w, h]]`) and display frames from `display.list`.

## Input tools

Prefer the structured tools (`grid.*`, `window.*`) when one does the job — they are deterministic. Reach for `input.*` when you need to operate an app's own UI.

- `input.mouse.position` — current cursor position
- `input.mouse.move(x, y)`
- `input.mouse.click([x], [y], [button], [count], [modifiers])` — omit x/y to click where the cursor is; `count=2` double-clicks; `button` is left/right/middle; `modifiers` like `"cmd"` or `"cmd+shift"`
- `input.mouse.drag(fromX, fromY, toX, toY, [button], [steps], [modifiers])` — press, move in steps, release
- `input.mouse.scroll([x], [y], [dx], [dy])` — pixel deltas; **positive dy scrolls content up** (toward the top), negative scrolls down
- `input.key.type(text)` — literal text into the focused window. Modifiers are cleared, so typing `"cmd+s"` produces those characters; it never triggers shortcuts. Handles unicode.
- `input.key.press(key, [count])` — a key or chord: `enter`, `escape`, `tab`, `space`, `backspace`, `up`/`down`/`left`/`right`, `f1`…`f12`, `cmd+s`, `cmd+shift+t`, `ctrl+c`, `alt+backspace`. Modifiers: `cmd`, `alt`/`opt`, `ctrl`, `shift`, `fn`. Join with `+`.

Rules that keep input reliable:

1. **Focus before typing.** `window.focus(windowId)` or click into the target, then type. Keystrokes go to whatever is focused.
2. **Screenshot after acting.** Every click/type/press should be followed by a `grid.screenshot` of the target before deciding the next step. Never chain several input calls blind.
3. Off-screen points are rejected with an error rather than clicked; an unknown key combo is rejected too.
4. Input calls are serialized and block until the events are posted (a 12-step drag is ~200ms).
5. Synthesized keys are real keys: a chord bound in BFD (theGrid's hotkeys) fires that binding.

## Tool reference

### Grid (grid.*)

**Focus:** `grid.focus(direction, [wrap], [extend])`, `grid.focus.cycle([forward])`, `grid.focus.cell(cell, [space])`

**Layout:** `grid.layout.list` [read-only], `grid.layout.current` [read-only], `grid.layout.get(layout)` [read-only], `grid.layout.apply(layout, [strategy])`, `grid.layout.cycle`, `grid.layout.refresh([display])`

**Cell:** `grid.cell.send(direction)`, `grid.cell.mode([mode])` — vertical / horizontal / tabs

**Window movement:** `grid.window.move(direction, [wrap], [extend])`, `grid.window.swap(direction)`

**Resize:** `grid.resize.grow([amount])`, `grid.resize.shrink([amount])` (default 0.1), `grid.resize.cell(direction, [amount])`, `grid.resize.reset([cell], [all])`

**Recording:** `grid.record.start([target], [id], [format], [fps], [duration], [output], [quality], [cursor], [width])` — target cell/window/screen/all, format gif/mp4/mov; `grid.record.stop`; `grid.record.toggle([target], [format])`

**State & config:** `grid.state.show` [read-only], `grid.state.reset` (destructive), `grid.config.show` [read-only]

**Screenshot:** `grid.screenshot([target], [id], [cursor], [display], [quality])` — see Coordinates above

**Utility:** `grid.terminal` — toggle the terminal overlay

### Window (window.*)

- `window.find([appName], [title], [pid])` — first visible window matching an exact app name, a title substring, or a process ID; returns `windowId`
- `window.focus(windowId)`, `window.raise(windowId)` (no focus change), `window.close(windowId)`
- `window.minimize(windowId)` / `window.unminimize(windowId)`
- `window.show(windowId)` / `window.hide(windowId)`

### Queries

- `ping`, `getServerInfo`
- `metadata.get` — focused window ID, active display UUID, active space ID
- `display.list` [read-only], `display.get([uuid], [active])`
- `dump` — every window with frame, app, title, spaces; every display and app. Large.
- `mouse.warp(windowId)` — cursor to the center of a window
- `pick.show` — opens the picker and **blocks until the user chooses**. Only call it when the user is at the keyboard and expects it.

## Interpreting data

### grid.state.show
```json
{"state": {"spaces": {"<spaceID>": {"layout": "tall-wide",
  "cells": {"left": {"lastFocusedWid": 1234, "windows": [1234, 5678]}}}}}}
```
Cell IDs are layout-specific strings (`left`, `right`, `main`, `top`…) — get valid ones from `grid.layout.get(layout)`. `lastFocusedWid` is the window "in" a cell; pass it as `id` to `grid.screenshot(target="cell", id="left")`.

### dump
`windows` is keyed by window ID; each has `frame: [[x, y], [w, h]]` in screen points, `appName`, `title`, `isMinimized`, `level`. Use it when `window.find` isn't specific enough or you need coordinates.

## Workflows

**See what's on screen**
```
grid.screenshot()                          # active display
grid.state.show + grid.layout.current      # structured
```

**Rearrange windows**
```
grid.layout.list → grid.layout.apply(layout="tall-wide") → grid.layout.refresh → grid.screenshot()
```

**Operate an app**
```
window.find(appName="Safari")                     → windowId
window.focus(windowId=...)
grid.screenshot(target="window", id="...")        → image + {frame, image}
# locate the control in the image, convert px → points with the formula
input.mouse.click(x=..., y=...)
input.key.type(text="hello")  /  input.key.press(key="cmd+s")
grid.screenshot(target="window", id="...")        # confirm
```

**Record a demo**
```
grid.record.start(target="screen", format="gif", fps=15)
… drive the demo with grid.* / input.* …
grid.record.stop                                  → ~/Desktop/thegrid-….gif
```

## Notes

- Window IDs are CGWindow IDs (numbers, passed as strings). Find them via `window.find` or `dump`.
- Recordings default to `~/Desktop/`.
- The MCP server connects to `/tmp/grid-server.sock`; override with `GRID_SOCKET` or `thegrid mcp serve --socket`.
- `thegrid mcp install` installs or refreshes this integration; the same tools are available from the shell as `thegrid input …`, `thegrid window …`, etc.
