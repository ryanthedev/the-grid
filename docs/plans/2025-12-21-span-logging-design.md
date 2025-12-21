# Span-Based Logging Design

## Overview

Add hierarchical span support to the simplified logging system. Spans provide start/stop markers with duration tracking, enabling debugging of slow commands, understanding event flow, and post-mortem analysis.

## Goals

1. **Debug slow commands** - See timing/duration at each layer to find bottlenecks
2. **Understand event flow** - Clear boundaries showing which events belong to which command
3. **Post-mortem analysis** - Easily find all events related to a specific command

## Schema

Field order: `ev` → `sid` → `tid` → `dur` → `err` → `data` → `ts`

| Field | Description |
|-------|-------------|
| `ev` | Event code - uses `.start`/`.end` suffix for span boundaries |
| `sid` | Span ID - dot-notation hierarchy (e.g., `a1b2`, `a1b2.srv`, `a1b2.srv.border`) |
| `tid` | Trace ID - same for all events in one command flow |
| `dur` | Duration in milliseconds - only on `.end` events |
| `err` | Error message - only present on failure |
| `data` | Event-specific payload |
| `ts` | Unix timestamp |

**Span boundary events** (`.start`/`.end`) always have both `sid` and `tid`.
**Intermediate events** have `tid`, and optionally `sid` if they belong to a specific span.

## Span Hierarchy

Dot-notation encodes parent-child relationships:

- `a1b2` → root span (CLI command)
- `a1b2.srv` → child of root (server handling)
- `a1b2.srv.border` → child of srv (border subsystem)

Example flow for `focus left`:

```
CLI                          Server
───                          ──────
cmd.start (sid: a1b2)
  │
  ├─► [socket call] ────────► srv.start (sid: a1b2.srv)
  │                             │
  │                             ├── state.start (sid: a1b2.srv.state)
  │                             ├── win.focus (tid: a1b2)
  │                             ├── state.end (sid: a1b2.srv.state, dur: 5)
  │                             │
  │                             ├── border.start (sid: a1b2.srv.border)
  │                             ├── border.update (tid: a1b2)
  │                             ├── border.end (sid: a1b2.srv.border, dur: 12)
  │                             │
  │   ◄──────────────────────── srv.end (sid: a1b2.srv, dur: 23)
  │
cmd.end (sid: a1b2, dur: 45)
```

## API Design

### CLI (Go)

Extend `jsonlog` package with span support:

```go
// Create a new trace (root span) - generates tid and sid
span := jsonlog.StartSpan("cmd", jsonlog.WithData(map[string]any{
    "cmd": "focus", "dir": "left",
}))

// Intermediate events use the trace
jsonlog.Log("win.resolve", jsonlog.WithTrace(span.Tid(), ""))

// End the span (calculates duration automatically)
span.End()

// Or end with error
span.EndWithError("window not found")

// Child span (inherits tid, extends sid with dot-notation)
child := span.StartChild("validate")
// child.Sid() returns "a1b2.validate"
child.End()
```

Span struct:

```go
type Span struct {
    tid   string
    sid   string
    start time.Time
}

func (s *Span) Tid() string
func (s *Span) Sid() string
func (s *Span) StartChild(name string, opts ...Option) *Span
func (s *Span) End()
func (s *Span) EndWithError(err string)
```

### Server (Swift)

Extend `JSONLogger` with span support:

```swift
// Start a span (receives tid from CLI via request, extends sid)
let span = await JSONLogger.shared.startSpan(
    "srv",
    tid: request.tid,
    parentSid: request.sid,
    data: ["method": request.method]
)
// span.sid is "a1b2.srv"

// Intermediate events use the trace
jlog("win.focus", data: ["wid": 123], tid: span.tid)

// Child span for subsystem
let borderSpan = await span.startChild("border", data: ["wid": 123])
// borderSpan.sid is "a1b2.srv.border"

// End spans
await borderSpan.end()
await borderSpan.end(err: "window not found")  // with error
await span.end()
```

Span struct:

```swift
struct Span {
    let tid: String
    let sid: String
    let start: Date

    func startChild(_ name: String, data: [String: Any]? = nil) async -> Span
    func end(err: String? = nil) async
}
```

## Trace Context Propagation

CLI passes trace context to server via socket request:

```json
{
  "id": 1,
  "method": "window.focus",
  "params": {"wid": 123},
  "tid": "a1b2",
  "sid": "a1b2"
}
```

Server extracts and continues the trace:

```swift
func handleMessage(_ data: Data) async {
    let request = try decode(data)

    let span = await JSONLogger.shared.startSpan(
        "srv",
        tid: request.tid,
        parentSid: request.sid,
        data: ["method": request.method]
    )

    // Handle request...

    await span.end()
}
```

## Example Output

**thegrid-cli.json:**
```jsonl
{"ev":"cmd.start","sid":"a1b2","tid":"a1b2","data":{"cmd":"focus","dir":"left"},"ts":1702840000}
{"ev":"cmd.end","sid":"a1b2","tid":"a1b2","dur":45,"ts":1702840045}
```

**thegrid-server.json:**
```jsonl
{"ev":"srv.start","sid":"a1b2.srv","tid":"a1b2","data":{"method":"window.focus"},"ts":1702840001}
{"ev":"state.start","sid":"a1b2.srv.state","tid":"a1b2","ts":1702840002}
{"ev":"win.focus","tid":"a1b2","data":{"wid":123},"ts":1702840003}
{"ev":"state.end","sid":"a1b2.srv.state","tid":"a1b2","dur":5,"ts":1702840007}
{"ev":"border.start","sid":"a1b2.srv.border","tid":"a1b2","data":{"wid":123},"ts":1702840008}
{"ev":"border.update","tid":"a1b2","data":{"action":"show"},"ts":1702840018}
{"ev":"border.end","sid":"a1b2.srv.border","tid":"a1b2","dur":12,"ts":1702840020}
{"ev":"srv.end","sid":"a1b2.srv","tid":"a1b2","dur":22,"ts":1702840023}
```

**Error case:**
```jsonl
{"ev":"border.end","sid":"a1b2.srv.border","tid":"a1b2","dur":12,"err":"window not found","ts":1702840020}
```

## Querying

Find all events for a trace:
```bash
grep '"tid":"a1b2"' ~/.local/state/thegrid/*.json
```

Find all span boundaries:
```bash
grep -E '"ev":"[^"]+\.(start|end)"' ~/.local/state/thegrid/*.json
```

Find errors:
```bash
grep '"err":' ~/.local/state/thegrid/*.json
```
