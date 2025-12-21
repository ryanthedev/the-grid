# Simplified Logging Design

## Overview

Replace the current multi-file logging system with two simple JSONL log files. Remove log levels, debug flags, and console output complexity.

## Log Files

| File | Purpose |
|------|---------|
| `~/.local/state/thegrid/thegrid-server.json` | Server logs (JSONL) |
| `~/.local/state/thegrid/thegrid-cli.json` | CLI logs (JSONL) |

No rotation - managed externally via scripts.

## Removed

- `events.jsonl`
- `grid-cli.log`
- `grid-server.log`
- `--debug` flag (both CLI and server)
- Log level configuration
- Console output (except server startup message)

## Server Startup Output

Only output on server start:

```
logging to /Users/r/.local/state/thegrid/thegrid-server.json
```

Nothing else to console.

## Log Schema

Format: JSONL (one JSON object per line)

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `ts` | yes | int | Unix timestamp |
| `ev` | yes | string | Event code for filtering |
| `msg` | no | string | Extra context when needed |
| `data` | no | object | Event-specific payload |
| `tid` | no | string | Trace ID |
| `sid` | no | string | Span ID |

### Examples

```jsonl
{"ts":1702840000,"ev":"srv.init"}
{"ts":1702840001,"ev":"win.focus","data":{"wid":123}}
{"ts":1702840002,"ev":"srv.error","msg":"invalid window","data":{"wid":456,"err":"not found"}}
{"ts":1702840003,"ev":"cmd.start","data":{"cmd":"focus","dir":"left"},"tid":"a1b2","sid":"c3d4"}
```

## Implementation

### Server (Swift)

Create `JSONLogger` actor:

```swift
actor JSONLogger {
    static let shared = JSONLogger()

    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil, tid: String? = nil, sid: String? = nil)
}
```

- Appends JSONL to `thegrid-server.json`
- On startup: print log path, then no more console output

### CLI (Go)

Create `jsonlog` package:

```go
func Log(ev string, opts ...Option)

// Options
func WithMsg(msg string) Option
func WithData(data map[string]any) Option
func WithTrace(tid, sid string) Option
```

- Appends JSONL to `thegrid-cli.json`

### Migration

1. Replace all `EventLog.shared.log()` calls with `JSONLogger.shared.log()`
2. Replace all `eventlog.Log()` calls with `jsonlog.Log()`
3. Convert `logging.Error/Warn/Info()` calls to `jsonlog.Log()` with appropriate `ev` codes
4. Delete old logging code and files
