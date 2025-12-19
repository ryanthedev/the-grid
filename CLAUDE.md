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

## Logging Requirements

### Event Logging (primary - for debugging/post-mortem)
- Use EventLog for all significant events (writes to `events.jsonl`)
- CLI (Go): `eventlog.Log("event.code", map[string]any{"key": value})`
- Server (Swift): `await EventLog.shared.log("event.code", ["key": value])`
- Event codes use dot notation: `cmd.start`, `win.move`, `srv.init`, `bdr.show`
- Use abbreviated keys: `wid` (window ID), `sid` (space ID), `pid`, `app`, `rid` (request ID)
- Output format: `{"t":1702840000,"ev":"cmd.start","cmd":"focus","rid":"a1b2"}`

### Console/File Logging (errors and warnings only)
- CLI uses zerolog (`logging.Error()`, `logging.Warn()`)
- Server uses swift-log for console output
- Reserve for errors, warnings, and user-facing messages

## Project Paths
- **Log files**: `~/.local/state/thegrid/`
  - `events.jsonl` - Unified event log (CLI + server, auto-rotates at 1MB)
  - `grid-cli.log` - CLI client logs (errors/warnings)
  - `grid-server.log` - Server logs (errors/warnings)
  - `state.json` - Runtime state
- **Config**: `~/.config/thegrid/config.yaml`
- **Server socket**: `/tmp/grid-server.sock`

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
grep -E "mss\.init|state\.init" ~/.local/state/thegrid/events.jsonl | tail -5
```

### Full rebuild and restart
```bash
make build && pkill -f grid-server && sleep 1 && \
  nohup ./grid-server/.build/debug/grid-server --debug > /dev/null 2>&1 &
```
