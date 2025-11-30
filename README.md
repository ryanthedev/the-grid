# theGrid

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
