---
name: thegrid
description: Control theGrid window manager and drive the Mac — screenshots, layouts, focus, window ops, mouse/keyboard input, recording. Use when you need to see what's on screen, rearrange windows, click or type into an app, or capture demos.
---

# theGrid — MCP Tools

theGrid is a macOS tiling window manager. Its MCP server (`thegrid mcp serve`) exposes 66 tools over a Unix socket to the running grid-server: query state, move windows, apply layouts, capture screenshots, read a window's accessibility tree, list and run menu bar commands, read and write the clipboard, synthesize mouse and keyboard input, record demos.

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

## Snapshot, screenshot, or query

- `ui.snapshot(windowId)` FIRST when you need to read a window or find a control. It returns the accessibility tree as text: exact labels and values, exact frames, no vision, no pixel math. It sees only that one window.
- `grid.screenshot` when you need to SEE (visual verification, layout, canvas or image content, apps whose tree is thin). Returns an inline image plus a JSON geometry block. Target a window, cell, or region — a full-display capture shows everything the user has open, so take one only for layout checks or when asked.
- `grid.state.show` / `dump` / `grid.layout.current` when you need DATA (window IDs, frames, cell assignments).
- A window/cell capture shows the window even when another window covers it. `coveredBy` in the geometry block names what is on top; a plain click there hits that app, not the one in your image.
- A `hint` about downscaling means digits, IDs and small text in that image are not trustworthy (an agent misread a 16-digit ID this way). Read them with `ui.value` / `ui.snapshot`, or zoom with `target="region"`.
- Do not screenshot too early: `settleMs` waits a fixed time, `waitTitle="Inbox"` waits for a window title (page loaded), `waitStable=true` waits until the picture stops changing. `timeoutMs` caps the wait (default 5000); the result reports `titleMatched` / `stable`.
- `display.list` first when targeting a display; `display` indexes are 0-based in `display.list` order and the default is the active display.
- `quality="low"` (default, long edge ≤1568px JPEG) is enough to check layout and find controls. Use `quality="high"` (full resolution; PNG, or JPEG when the PNG would be too large to send) only when you must read small text.
- `target="region"` and `target="full"` show the SCREEN, i.e. whatever is on top there. To look at one particular window, covered or not, use `target="window"`. A region that crosses a display edge is clipped to one display; the result then says `clipped` and echoes what you `requested`.
- On a wide display a full capture is still coarse (3840×1080 → 1568×441). Zoom with `target="region"` and `x`, `y`, `width`, `height` in screen points; the region is clipped to the display it overlaps most and the returned `frame` is what was actually captured.

## Coordinates: screenshot pixels → screen points

All `input.*` coordinates are **global screen points** (top-left origin, multi-display aware; a display above the main one has negative y). They are NOT screenshot pixels: Retina capture is 2× points and the low-quality image is downscaled again.

Every `grid.screenshot` returns, after the image, a text block like:

```json
{"target":"window","windowId":14488,"frame":{"x":500,"y":-1031,"width":656,"height":422},"image":{"width":1024,"height":658}}
```

**You do not have to do this arithmetic.** `input.mouse.click/move/scroll/drag` and `window.at` take `px`/`py` (drag: `fromPx`…`toPy`) in pixels of the screenshot you are looking at (refused if that window has moved since; re-shoot) — the latest one this session took, or the one whose `shot` number you pass — and convert them for you. The formula, for when you need it:

To click something you see at pixel `(px, py)` in that image:

```
x = frame.x + px * frame.width  / image.width
y = frame.y + py * frame.height / image.height
```

Window and cell captures exclude the shadow, so image edges are window edges. Window frames also come from `dump` (`windows[wid].frame` = `[[x, y], [w, h]]`) and display frames from `display.list`.

## UI tools (accessibility)

```
ui.snapshot(windowId="14442")
{"count":212,"windowId":14442}
[14442:1] AXWindow "Inbox" (0,-1080 1280x1080) focused
  [14442:2] AXToolbar (0,-1052 1280x52)
    [14442:3] AXButton "Compose" (12,-1040 80x28) press
    [14442:4] AXTextField desc="Search" value="invoices" (900,-1040 300x28)
```

Each line is `[ref] role "title" value="…" desc="…" for="…" (x,y WxH)` plus flags: `press`, `selected`, `offscreen`, `focused`, `disabled`. A table or list row is one line, its cells joined: `AXRow "CLAUDE.md | Aug 2, 2026 | 7 KB | Markdown Document"`. `for="…"` is the label borrowed from the text beside a control that has none of its own (the switches in System Settings). Frames are global screen points, so a frame's center can go straight into `input.mouse.click`. Unlabelled containers are walked but not printed; content scrolled out of the window is skipped.

- `ui.query(windowId, [role], [text], [pressable], [limit])` — **find, don't read.** The same walk as a snapshot, returning only the matches, flat, with refs: `ui.query(windowId, role="button", text="save")` is three lines where a snapshot is four hundred. `role` takes `button` or `AXButton` (subroles too: `switch`); `text` matches title, value, description and the borrowed `for=` label, case-insensitively. It searches offscreen content too. Snapshot once to learn an app; query from then on.
- `ui.wait(windowId, [expectText], [expectGone], [expectTitle], [timeoutMs])` — wait for the window to show text, stop showing it, or take a title, instead of sleeping and looking.
- `ui.value(ref)` — the node's full text. The outline clips values at 120 characters; use this for a document, a long field, or any ID you must get exactly right.
- `ui.press(ref)` — AXPress, with fallbacks (the result's `via` says which): Finder lists AXPress on its disclosure triangles and then refuses it, so those toggle the row's disclosing state instead. Never moves the cursor. Ordinary buttons do not take keyboard focus from the user, but opening a menu or pop-up activates that app (the menu's items then appear in the next snapshot, sometimes twice under two parents — either ref works). Try it first on anything flagged `press`.
- `ui.select(ref)` — select a row, list item or tab (sidebar navigation, picking a file) with no pointer and no focus change. The `selected` flag shows where you are.
- `ui.scrollTo(ref)` — bring a node into view. Content scrolled out of view is left out of the outline unless you pass `includeOffscreen=true`, which lists it flagged `offscreen`.
- `ui.setValue(ref, value)` — numbers work too: a slider or scroll bar (0–1), a checkbox or disclosure triangle (0/1).
- `ui.setValue(ref, value)` — replace a text field's whole value. Some apps (web forms especially) ignore this; fall back to `ui.click` + `input.key.type`.
- `ui.click(ref)` — synthesized click at the node's current center. Moves the cursor. Always guarded: the ref's window is raised and focused first and the click is refused if another app still covers the point.
- Refs look like `14442:7` and live until the next full `ui.snapshot` of that window (including `observe="snapshot"` and any other client's snapshot). Numbers are never reused, so an old ref fails with "unknown ref" rather than pressing something else. After anything that changes the UI, snapshot again.
- `"truncated":"maxNodes"` or `"deadline"` in the header means the tree was cut (default 400 nodes, 3 s); `"unresponsive"` means the app stopped answering mid-walk and what you have is partial. Expand one branch with `ui.snapshot(ref="14442:9")` — that keeps existing refs — or raise `maxNodes`.
- An unlabelled control prints its subrole instead: `AXButton:AXCloseButton`.
- Chrome exposes its toolbar and tabs but not the page; read web content with a window screenshot (or browser tools). Safari exposes the page.
- "not reachable through accessibility": the app did not answer or did not list that window — it is hung, minimized, or on a space that is not visible. macOS only lists an app's windows on visible spaces, and `window.focus` fails on those windows for the same reason. `space.list` tells you which it is; see Spaces below.
- A thin tree (a handful of nodes) means the app exposes little: Electron apps build theirs only after the first request, so snapshot once more; canvas-drawn UIs never will — use screenshots there.
- `resolvedWindowId` in the header means the app's only AX window was substituted for the ID you asked for; check it is the window you meant.
- The grid server's own windows (notification panel, terminal overlay) cannot be snapshotted.

## Clipboard

```
clip.read
{"changeCount":412,"hasText":true,"text":"INV-2026-0042","bytes":13,"types":["public.utf8-plain-text"]}
```

The clipboard is the user's, and it is shared with everything they do while you work.

- `clip.read([type])` [read-only] — the clipboard's text, at most 64 KB (`truncated`, `bytes` and `returnedBytes` say when it was cut). Text only: images and files show up in `types` and are not read.
- `clip.write(text)` — replaces the clipboard, every type of it, with text (up to 1 MB). **That destroys what the user had copied.** `clip.read` first; when you are done, write their text back if it was text, and tell them if it was not.
- `changeCount` goes up whenever anything changes the clipboard. It is how you judge a copy by its effect: read the count, `menu.invoke(… "Edit > Copy")` or `input.key.press cmd+c`, read again; an unchanged count means nothing was copied, whatever the call returned.
- **Refused:** a clipboard marked `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`. Password managers mark secrets that way. Do not look for another route to the value; ask the user.
- Good for: getting text out of an app whose tree does not expose it (select, copy, `clip.read`), and pasting long or exact text where typing is slow or the app mangles keystrokes (`clip.write`, then `input.key.press(key="cmd+v", windowId=…)`).
- Contents are never logged by the server, only sizes.

## Spaces

```
space.list
{"activeDisplayUUID":"FCEC…","displays":[
  {"uuid":"FCEC…","name":"C49HG9x (2)","isActive":true,"currentSpaceId":"3","spaces":[
    {"id":"3","index":1,"type":"user","isCurrent":true,"windows":[{"windowId":"17404","appName":"TextEdit","title":"notes.txt"}]},
    {"id":"4","index":2,"type":"user","isCurrent":false,"windows":[]}]},
  {"uuid":"89ED…","currentSpaceId":"1858","spaces":[{"id":"6","type":"user",…},{"id":"1858","type":"fullscreen","isCurrent":true,…}]}]}
```

Each display shows one space at a time. A window on a space where `isCurrent` is false cannot be snapshotted, clicked or focused.

- `space.list` [read-only] — displays, their spaces, which is current, and the windows on each. Start here when a window "is not reachable". Entries with an empty title are mostly apps' helper windows: find yours by title or by the windowId you already have.
- **A `fullscreen` space is the user's video, presentation or fullscreen app. Leave that display alone:** do not switch it, do not move windows onto or off it, do not click there. The tools below refuse, and the refusal is not an obstacle to get around: ask the user.
- `window.pull(windowId)` — bring a window to the current space of the active display without switching anything. Refused for a window on a fullscreen space and when the active display is showing one. It does not focus: follow with `window.focus`.
- `space.switch(spaceId, [leaveFullscreen])` — show that space on its own display; other displays are untouched. Refused while that display shows a fullscreen space unless `leaveFullscreen=true`, which is for when the user asked for exactly that. Targets must be `user` spaces; to reach a fullscreen app, focus its window.
- Both actions read their effect back from the window server and **fail when nothing happened**, because the underlying calls report nothing. On macOS 26 the window server ignores a move of a window that sits on a non-visible space, so expect `window.pull` to fail with "was not pulled" there; `space.switch` has not been exercised on a live machine yet. When either fails, do not retry in a loop: ask the user to bring the window or the space forward (ctrl+arrow, Mission Control).
- After a successful switch, take a new `ui.snapshot`; refs and screenshots from before describe the old space.

## Menu tools

```
menu.snapshot(app="Finder", text="go to")
{"app":"Finder","count":1,"pid":650,"scanned":182}
Go > Go to Folder…  [cmd+shift+G]  enabled
```

The menu bar is the app's own index of what it can do, with exact names, and it is readable without opening anything.

- `menu.snapshot(app | windowId, [text], [enabled], [limit])` — one line per command: `path  [shortcut]  enabled|disabled  [checked]`. Opens no menu, moves nothing, does not activate the app. A big app has a few hundred lines, so pass `text` (matches the path or the shortcut: `"export"`, `"view > "`, `"cmd+shift"`). The shortcut is in `input.key.press` syntax. The Apple menu is left out. Same-named lines are alternates (hold option to see them in the real menu).
- **An app in the background reports its document commands disabled** (Save, Select All, Find…): it has no key window. That is not the state you will get once it is in front, so do not conclude from a background snapshot that a command is unavailable.
- `menu.invoke(app | windowId, path)` — runs the command: `menu.invoke(windowId="17269", path="Edit > Find > Find…", expectText="find next")`. **It activates the app** and takes keyboard focus from the user: with `windowId` that window is focused first so the command acts on it (prefer this); with `app` alone the app comes forward with whatever window it had, which can switch spaces. No menu is drawn and the cursor does not move. Case is ignored, `...` matches `…`, and a trailing ellipsis may be left off.
- Refused, with nothing pressed: a disabled command (checked only after the app is in front), a path that names a submenu, a path that does not exist (the error lists what is at that level). AXPress on a disabled menu item reports success and does nothing, which is why the tool checks instead of trusting the press.
- A command that ends in `…` opens a dialog or sheet: follow with `ui.snapshot` of the window. Give `expectText` / `expectGone` / `expectTitle` so the effect is the verdict.
- Prefer `menu.invoke` over `input.key.press` with a shortcut when you know the command's name: it cannot land in the wrong app, and it says so when the command is disabled instead of doing nothing.

## Input tools

Prefer the structured tools (`grid.*`, `window.*`, `ui.*`) when one does the job — they are deterministic. Reach for `input.*` when the accessibility tree does not reach what you need.

- `input.mouse.position` — current cursor position
- `input.mouse.move(x, y)`
- `input.mouse.click([x], [y], [button], [count], [modifiers])` — omit x/y to click where the cursor is; `count=2` double-clicks; `button` is left/right/middle; `modifiers` like `"cmd"` or `"cmd+shift"`
- `input.mouse.drag(fromX, fromY, toX, toY, [button], [steps], [modifiers])` — press, move in steps, release
- `input.mouse.scroll([x], [y], [dx], [dy])` — pixel deltas; **positive dy scrolls content up** (toward the top), negative scrolls down
- `input.key.type(text, [windowId])` — literal text into the focused window. Modifiers are cleared, so typing `"cmd+s"` produces those characters; it never triggers shortcuts. Handles unicode.
- `input.key.press(key, [count], [windowId])` — a key or chord: `enter`, `escape`, `tab`, `space`, `backspace`, `up`/`down`/`left`/`right`, `f1`…`f12`, `cmd+s`, `cmd+shift+t`, `ctrl+c`, `alt+backspace`. Modifiers: `cmd`, `alt`/`opt`, `ctrl`, `shift`, `fn`. Join with `+`.

**One round trip instead of two.** Every `input.*` action, `ui.press`/`ui.setValue`/`ui.click` and `window.focus` takes `observe="snapshot"` or `observe="screenshot"` (plus `settleMs`, default 250): the look at the result comes back in the same call. `batch(steps="[{\"tool\":…,\"args\":{…}}, …]")` runs up to 20 tools in order, stops at the first failure, and can end with an observing step. `observe="snapshot"` resets that window's refs, like any full snapshot.

**Judge by effect, not by return code.** Every action tool also takes `expectText`, `expectGone` and `expectTitle` (with `timeoutMs`, default 3000): after acting, the server polls the target window until the expectation holds, and the call FAILS if it never does. A success return only means the event was delivered — Finder answers AXPress with an error and expands the folder anyway; a button can accept a press and do nothing because a sheet is in the way. State what you expect: `ui.press(ref, expectText="Saved")`, `input.key.press(key="enter", windowId=…, expectTitle="Inbox")`, `ui.press(deleteRef, expectGone="draft.txt")`. When an expectation fails, look before retrying: the action may have worked slowly, and repeating it would do it twice.

**Errors come with the next move.** A failure whose cause is known ends with a `Next:` line (AXPress refused → ui.click; AXValue ignored → click and type; window on a hidden space; focus not taken; point covered; stale shot). Follow it before improvising. An outline of Chrome or of a terminal carries a `hint` saying the tree will not help and what to use instead.

Rules that keep input reliable:

0. **Pass `windowId` when clicking.** `input.mouse.click/drag/scroll` with `windowId` raise and focus that window, then check which window is actually frontmost at the point; if another app covers it, nothing is clicked and the error names the culprit. Without `windowId` the click goes to whatever is on top. `window.at(x, y)` tells you what that is.
1. **Pass `windowId` when typing.** `input.key.type` and `input.key.press` then focus that window, confirm with the OS that it really holds keyboard focus — after focusing, and again before every 5-character chunk or key repeat — and stop the moment it is lost; the error says how much was already posted. Guarded keys are delivered straight to the target app, so another app taking focus cannot receive them (another window of the same app still can, for at most one chunk). An app that is hung and will not report its focused window counts as not focused. Without `windowId`, keystrokes go to whatever is focused. `windowId` picks the window, not the field: click or `ui.click` the field first.
2. **Look after acting.** Follow every click/type/press with a `ui.snapshot` or `grid.screenshot` of the target before deciding the next step. Never chain several input calls blind.
3. Off-screen points are rejected with an error rather than clicked; an unknown key combo is rejected too.
4. Input calls are serialized and block until the events are posted (a 12-step drag is ~200ms). Repeat counts cap at 100 and drag steps at 500.
5. Two delivery paths. Without `windowId`, keys and all mouse events go through the HID event tap like real input: a chord bound in BFD (theGrid's hotkeys) fires that binding, and every event carries `eventSourceUserData = 0x47524944` ("GRID") so a tap can tell it from the user's. With `windowId`, keys go straight to the target process and never pass an event tap: BFD chords do NOT fire, key remappers do not apply, and nothing watching taps can see or stop them.
6. Password fields: `ui.setValue` on one, and guarded typing while the caret is in one, are refused unless the call passes `allowSecure=true`. Their values are never read.

## Tool reference

### Grid (grid.*)

**Focus:** `grid.focus(direction, [wrap], [extend])`, `grid.focus.cycle([forward])`, `grid.focus.cell(cell, [space])`

**Layout:** `grid.layout.list` [read-only], `grid.layout.current` [read-only], `grid.layout.get(layout)` [read-only], `grid.layout.apply(layout, [strategy])`, `grid.layout.cycle`, `grid.layout.refresh([display])`

**Cell:** `grid.cell.send(direction)`, `grid.cell.mode([mode])` — vertical / horizontal / tabs

**Window movement:** `grid.window.move(direction, [wrap], [extend])`, `grid.window.swap(direction)`

**Resize:** `grid.resize.grow([amount])`, `grid.resize.shrink([amount])` (default 0.1), `grid.resize.cell(direction, [amount])`, `grid.resize.reset([cell], [all])`

**Recording:** `grid.record.start([target], [id], [format], [fps], [duration], [output], [quality], [cursor], [width])` — target cell/window/screen/all, format gif/mp4/mov; `grid.record.stop`; `grid.record.toggle([target], [format])`

**State & config:** `grid.state.show` [read-only], `grid.state.reset` (destructive), `grid.config.show` [read-only]

**Screenshot:** `grid.screenshot([target], [id], [x], [y], [width], [height], [cursor], [display], [quality])` — target full/window/cell/region; see Coordinates above

**Utility:** `grid.terminal` — toggle the terminal overlay

### Window (window.*)

- `window.find([appName], [title], [pid])` — every visible window matching an exact app name, a title substring, or a process ID, in `matches` (windowId, title, appName, frame). Read the titles: with several windows or Chrome profiles, top-level `windowId` is just the first match.
- `window.at(x, y)` — the window a click at that point would reach
- `window.focus(windowId)`, `window.raise(windowId)` (no focus change), `window.close(windowId)`
- `window.minimize(windowId)` / `window.unminimize(windowId)`
- `window.show(windowId)` / `window.hide(windowId)`

### Clipboard

- `clip.read([type])` [read-only] — text (≤64 KB), `changeCount`, `types`; refused for concealed or transient contents
- `clip.write(text)` — replaces the user's clipboard; read first, restore after

### Spaces

- `space.list` [read-only] — displays → spaces (id, type, isCurrent) → windows
- `space.switch(spaceId, [leaveFullscreen])` — refused while the display shows a fullscreen space
- `window.pull(windowId)` — to the active display's current space; never off or onto a fullscreen space

### UI (ui.*)

- `ui.snapshot([windowId], [ref], [includeOffscreen], [maxNodes], [maxDepth])` [read-only] — see UI tools above
- `ui.query(windowId, [role], [text], [pressable], [limit])` [read-only], `ui.wait(windowId, [expectText], [expectGone], [expectTitle], [timeoutMs])` [read-only]
- `ui.select(ref)`, `ui.scrollTo(ref)`
- `ui.value(ref)` [read-only], `ui.press(ref)`, `ui.setValue(ref, value)`, `ui.click(ref, [button], [count])`
- `batch(steps)` — several tools in one call

### Menu (menu.*)

- `menu.snapshot([app], [windowId], [text], [enabled], [limit])` [read-only] — every menu bar command with shortcut and state; see Menu tools above
- `menu.invoke(path, [app], [windowId])` — run a command by path; activates the app

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
ui.query(windowId="...", role="button", text="compose")   → the one ref you need
ui.press(ref="...", expectText="New Message")             # act, and let the effect be the verdict
ui.click(ref="...")                               # put the caret in a field
input.key.type(text="hello", windowId="...")      # refuses unless that window has focus
input.key.press(key="enter", windowId="...")
ui.snapshot(windowId="...")                       # confirm
```

**Run a command by name**
```
menu.snapshot(windowId="...", text="find…")       → Edit > Find > Find…  [cmd+F]  enabled
menu.invoke(windowId="...", path="Edit > Find > Find…", expectText="find next")
ui.snapshot(windowId="...")                       # the find bar it opened
```

**Operate an app the tree does not reach**
```
grid.screenshot(target="window", id="...")        → image + {frame, image}
# locate the control in the image, convert px → points with the formula
input.mouse.click(x=..., y=...)
grid.screenshot(target="window", id="...")        # confirm
```

**Record a demo**
```
grid.record.start(target="screen", format="gif", fps=15)
… drive the demo with grid.* / input.* …
grid.record.stop                                  → ~/Desktop/thegrid-….gif
```

## What each kind of app gives you

- **Native AppKit/SwiftUI apps** (Finder, System Settings, Calculator, TextEdit, Messages, Photos): rich tree. Work entirely with `ui.*`; no screenshots, no focus change.
- **Chrome**: toolbar and tabs only. Screenshot the window, click by `px`/`py` with `windowId`, wait with `waitTitle`. Keys: `cmd+l`, type the URL, `enter` as one `batch`. A single `cmd+q` does not quit Chrome when "Warn Before Quitting" is on.
- **Terminals** (kitty, Ghostty): one text area or nothing. Screenshot to read; type with `windowId`.
- **Windows on a space that is not visible**: unreachable by AX and by `window.focus`. `space.list` finds them; `window.pull` or `space.switch` may bring them within reach (see Spaces), otherwise ask the user.
- Opening a menu by `ui.press` activates that app, and so does `menu.invoke`; pressing ordinary buttons, `ui.select`, `ui.setValue`, `ui.value` and `menu.snapshot` do not.

## Notes

- Window IDs are CGWindow IDs (numbers, passed as strings). Find them via `window.find` or `dump`.
- Recordings default to `~/Desktop/`.
- The MCP server connects to `/tmp/grid-server.sock`; override with `GRID_SOCKET` or `thegrid mcp serve --socket`.
- `thegrid mcp install` installs or refreshes this integration; most tools are also available from the shell: `thegrid input …`, `thegrid ui …`, `thegrid menu snapshot|invoke …`, `thegrid space list|switch|pull …`, `thegrid clip read|write …`, `thegrid window …`, `thegrid state show`, `thegrid dump` (full state as JSON, for jq) and `thegrid window find --app NAME --title TEXT` (one `ID<TAB>title` line per match). Screenshots, `batch` and `observe` exist only as MCP tools.
