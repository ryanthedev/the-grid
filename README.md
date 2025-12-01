<video src="thegridvid.mp4" autoplay loop muted playsinline></video>

# the grid

> The Grid. A digital frontier. I tried to picture clusters of information as they moved through the computer. What did they look like? Ships? Motorcycles? Were the circuits like freeways? I kept dreaming of a world I thought I'd never see. And then, one day... I got in.

macOS window manager with grid-based tiling layouts.

## Build & Run

```bash
# Server (Swift)
cd grid-server && swift build
.build/debug/grid-server

# CLI (Go)
cd grid-cli && make build
./bin/grid ping
```

## Requirements

- macOS 13+
- Accessibility permissions

See [grid-server/README.md](grid-server/README.md) and [grid-cli/README.md](grid-cli/README.md) for details.
