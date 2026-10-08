<div align="center">
  <video src="https://github.com/user-attachments/assets/5a6156ec-975a-4eac-a424-010522c1c180" autoplay loop muted playsinline></video>
</div>
# the grid

> The Grid. A digital frontier. I tried to picture clusters of information as they moved through the computer. What did they look like? Ships? Motorcycles? Were the circuits like freeways? I kept dreaming of a world I thought I'd never see. And then, one day... I got in.

macOS window manager with grid-based tiling layouts.

## Install

```bash
brew tap ryanthedev/thegrid && brew install thegrid
```

## Claude Code

The CLI ships an MCP server (48 tools: grid, window, query, screenshot, and mouse/keyboard input) and a skill. One command registers both:

```bash
thegrid mcp install     # registers `thegrid mcp serve` with Claude Code, writes ~/.claude/skills/thegrid/SKILL.md
```

Restart Claude Code, then `claude mcp list` should show `thegrid` connected. `thegrid mcp uninstall` reverses it.

The same input tools are available from the shell: `thegrid input click 800 400`, `thegrid input type "hello"`, `thegrid input key cmd+s`, `thegrid input scroll 0 -300`, `thegrid input drag X1 Y1 X2 Y2`.

## Build & Run

```bash
make run                # build everything, restart the dev service
make cli                # just the CLI (grid-server/.build/debug/grid-cli)
make test
```

## Requirements

- macOS 13+
- Accessibility permissions
