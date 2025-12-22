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

### Usage

CLI (Go):
```go
jsonlog.Log("cmd.start", jsonlog.WithData(map[string]any{"cmd": "focus"}))
jsonlog.Log("err.focus", jsonlog.WithMsg("window not found"), jsonlog.WithData(map[string]any{"wid": 123}))
```

Server (Swift):
```swift
jlog("srv.init")
jlog("win.focus", data: ["wid": 123])
await JSONLogger.shared.log("err.bounds", msg: "failed to get bounds", data: ["wid": 456])
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
let span = await JSONLogger.shared.startSpan("srv", tid: tid, parentSid: parentSid, data: ["method": method])

// Child span
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
- **Log files**: `~/.local/state/thegrid/`
  - `thegrid-cli.json` - CLI logs (JSONL)
  - `thegrid-server.json` - Server logs (JSONL)
  - `state.json` - Runtime state
- **Config**: `~/.config/thegrid/config.yaml`
- **Server socket**: `/tmp/grid-server.sock`

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

# Server binary modification time (confirms rebuild)
stat -f "%Sm" grid-server/.build/debug/grid-server

# Quick ping to verify server is responding
./grid-cli/bin/thegrid ping
```

### Check recent server events
```bash
# Last 5 server startup events
grep -E '"ev":"srv\.start"|"ev":"state\.init"' ~/.local/state/thegrid/thegrid-server.json | tail -5
```

### Full rebuild and restart
```bash
make run
```
