# Development Guidelines

## Priority: Build First, Validate Second
- Focus on implementing working code that meets requirements
- Skip comprehensive documentation unless explicitly requested
- No e2e tests unless specifically asked

## Testing Strategy
- Write minimal unit tests only to validate core logic/assumptions
- 3-5 targeted tests maximum per feature
- It's acceptable to create temporary tests and delete them after validation
- Tests should prove the approach works, not provide coverage

## Logging

All logging goes to JSONL files in `~/.local/state/thegrid/`:
- `thegrid-cli.json` - CLI logs
- `thegrid-server.json` - Server logs

### Log Schema

```jsonl
{"ts":1702840000,"ev":"win.focus","data":{"wid":123}}
{"ts":1702840001,"ev":"srv.error","msg":"invalid window","data":{"wid":456}}
```

| Field | Required | Description |
|-------|----------|-------------|
| `ts` | yes | Unix timestamp |
| `ev` | yes | Event code (e.g., `win.focus`, `cmd.start`) |
| `msg` | no | Extra context |
| `data` | no | Event-specific payload |
| `tid` | no | Trace ID |
| `sid` | no | Span ID |

### Log Rotation (server)

`thegrid-server.json` rotates by size. When a batch would push it past the
ceiling, the archive chain shifts down (`.json` → `.json.1` → `.json.2` …),
the oldest archive is dropped, and a `log.rotate` event is written at the head
of the fresh file. Total usage is bounded at `maxBytes × (keep + 1)`.

| Env var | Default | Description |
|---------|---------|-------------|
| `THEGRID_LOG_MAX_BYTES` | `33554432` (32 MB) | Per-file ceiling. `0` disables rotation. |
| `THEGRID_LOG_KEEP` | `5` | Archives kept alongside the live file. `0` discards with no history. |
| `THEGRID_LOG_PATH` | unset | Full override of the log file path. |

Only the server rotates. The CLI and notify logs have no rotation — they are
orders of magnitude smaller.

**Tests never write to the real log.** The suite exercises production code that
calls `jlog`, so `swift test` used to append to `thegrid-server.json` (and,
once rotation existed, could rotate it out from under the running server).
When XCTest is loaded the log is redirected to
`$TMPDIR/thegrid-tests/thegrid-server.json`. Note `XCTestConfigurationFilePath`
is *not* set under `swift test` — the detection uses whether the XCTest class
is loaded.

### Usage

CLI (Go):
```go
jsonlog.Log("cmd.start", jsonlog.WithData(map[string]any{"cmd": "focus"}))
jsonlog.Log("err.focus", jsonlog.WithMsg("window not found"), jsonlog.WithData(map[string]any{"wid": 123}))
```

Server (Swift):
```swift
// Convenience wrapper (uses TaskLocal trace context)
jlog("srv.init")

// With explicit data
JSONLogger.shared.log("win.focus", data: ["wid": 123])
JSONLogger.shared.log("err.bounds", msg: "failed to get bounds", data: ["wid": 456])
```

### Span-Based Logging

For timing and correlation, use spans:

CLI (Go):
```go
span := jsonlog.StartSpan("cmd", jsonlog.WithData(map[string]any{"cmd": "focus"}))
defer span.End()

// Child span
child := span.StartChild("validate")
// ... work ...
child.End()

// End with error
span.EndWithError("window not found")
```

Server (Swift):
```swift
let span = JSONLogger.shared.startSpan("srv", tid: tid, parentSid: parentSid, data: ["method": method])

// Child span (async)
let child = await span.startChild("border", data: ["wid": 123])
await child.end()

await span.end()
```

Output format:
```jsonl
{"ev":"cmd.start","sid":"a1b2","tid":"a1b2","data":{"cmd":"focus"},"ts":1702840000}
{"ev":"cmd.end","sid":"a1b2","tid":"a1b2","dur":45,"ts":1702840045}
```

## Project Paths

Both CLI and server follow the XDG Base Directory Specification:

- **State**: `$XDG_STATE_HOME/thegrid/` (default: `~/.local/state/thegrid/`)
  - `thegrid-cli.json` - CLI logs (JSONL)
  - `thegrid-server.json` - Server logs (JSONL)
  - `state.json` - Runtime state
  - `GridServer.app/` - Server app bundle (deployed by `make dev`)
- **Config**: `$XDG_CONFIG_HOME/thegrid/` (default: `~/.config/thegrid/`)
  - `config.yaml` - CLI configuration
  - `config.local.yaml` - Local overrides
  - `bfd.yaml` - BFD hotkey configuration
  - `bfd.local.yaml` - Local hotkey overrides
- **Server socket**: `/tmp/grid-server.sock` (configurable via `--socket` CLI flag)

## Config Layering

Both CLI and BFD configs support machine-specific overrides via `.local.yaml` files:

- `~/.config/thegrid/config.yaml` - Base CLI config (committed)
- `~/.config/thegrid/config.local.yaml` - Local overrides (gitignored)
- `~/.config/thegrid/bfd.yaml` - Base BFD hotkey config (committed)
- `~/.config/thegrid/bfd.local.yaml` - Local overrides (gitignored)

Local files are deep-merged over base config. Only include fields you want to override:

```yaml
# config.local.yaml - override just the spacing for this machine
settings:
  baseSpacing: 12
```

## XDG Config Resolution

Both CLI and server support the XDG Base Directory Specification:

| Variable | Default | Description |
|----------|---------|-------------|
| `$XDG_CONFIG_HOME` | `~/.config` | User config directory |
| `$XDG_CONFIG_DIRS` | `/etc/xdg:/opt/homebrew/etc:/usr/local/etc` | System config paths (colon-separated) |
| `$XDG_STATE_HOME` | `~/.local/state` | Runtime state (logs) |

### Config Search Order

Configs are merged in this order (lowest to highest priority):
1. Built-in defaults (hardcoded)
2. System configs (`$XDG_CONFIG_DIRS/thegrid/`)
3. User config (`$XDG_CONFIG_HOME/thegrid/`)
4. Local overlay (`$XDG_CONFIG_HOME/thegrid/*.local.yaml`)

### Debugging Config Resolution

```bash
# Show config sources and XDG paths
thegrid config sources

# Show merged config as YAML
thegrid config show

# Validate config
thegrid config validate
```

## BFD Hotkey Configuration

BFD (Binary Focused Dispatcher) handles keyboard shortcuts. Config at `$XDG_CONFIG_HOME/thegrid/bfd.yaml`:

```yaml
shell: /bin/zsh  # Shell for command execution
vars:
  grid: ~/.local/bin/thegrid
defaults:
  repeat: false
  rate_limit: 50  # ms between repeats
blacklist:
  - com.apple.finder  # Apps where hotkeys are disabled
hotkeys:
  ctrl-h: ${grid} focus left
  ctrl-j: ${grid} focus down
apps:
  com.example.app:
    ctrl-h: ~  # Passthrough (let app handle it)
```

Supports `.local.yaml` overrides like CLI config.

## Documentation Research
- ALWAYS search online for API docs, library usage examples
- Run `--help`, `man`, or equivalent for CLI tools before using
- Verify syntax and options rather than assuming
- Check official docs for breaking changes

## Response Style
- Keep explanations concise
- Code first, explanation after
- No apologetic language or over-explaining
- Comments always on their own line above the code, never inline to the right

## Verifying Builds & Server State

### Check if server is running with current build
```bash
# Server process start time (confirms restart)
ps -o lstart= -p $(pgrep -f "grid-server" | head -1) 2>/dev/null

# Deployed server binary modification time
stat -f "%Sm" ~/.local/state/thegrid/GridServer.app/Contents/MacOS/grid-server

# Quick ping to verify server is responding
thegrid ping
```

### Check recent server events
```bash
# Last 5 server startup events
grep '"ev":"srv.start"' ~/.local/state/thegrid/thegrid-server.json | tail -5
```

### Full rebuild and restart
```bash
make run
```
