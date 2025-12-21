# Span-Based Logging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add hierarchical span support to the logging system for timing, boundaries, and correlation.

**Architecture:** Extend existing `jsonlog` (Go) and `JSONLogger` (Swift) with `Span` types that track start time, generate dot-notation span IDs, and emit `.start`/`.end` events with duration. CLI passes trace context to server via `_trace` param (already exists), server extracts and continues the span hierarchy.

**Tech Stack:** Go (CLI), Swift (Server), JSONL logging

---

## Task 1: Add Span Type to CLI jsonlog Package

**Files:**
- Modify: `grid-cli/internal/jsonlog/jsonlog.go`
- Test: `grid-cli/internal/jsonlog/jsonlog_test.go`

**Step 1: Add Span struct and ID generator**

Add to `jsonlog.go` after the `LogEntry` struct:

```go
// Span represents a timed operation with start/end events
type Span struct {
	tid   string
	sid   string
	name  string
	start time.Time
}

// generateID creates a short random ID (4 chars)
func generateID() string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 4)
	for i := range b {
		b[i] = chars[time.Now().UnixNano()%int64(len(chars))]
		time.Sleep(time.Nanosecond)
	}
	return string(b)
}
```

**Step 2: Add StartSpan function**

Add after `generateID`:

```go
// StartSpan creates a new root span and logs the start event
func StartSpan(name string, opts ...Option) *Span {
	id := generateID()
	span := &Span{
		tid:   id,
		sid:   id,
		name:  name,
		start: time.Now(),
	}

	entry := LogEntry{
		Ev:  name + ".start",
		Sid: span.sid,
		Tid: span.tid,
		Ts:  time.Now().Unix(),
	}
	for _, opt := range opts {
		opt(&entry)
	}
	writeEntry(entry)

	return span
}
```

**Step 3: Add Span methods**

Add after `StartSpan`:

```go
// Tid returns the trace ID
func (s *Span) Tid() string { return s.tid }

// Sid returns the span ID
func (s *Span) Sid() string { return s.sid }

// StartChild creates a child span with dot-notation sid
func (s *Span) StartChild(name string, opts ...Option) *Span {
	child := &Span{
		tid:   s.tid,
		sid:   s.sid + "." + name,
		name:  name,
		start: time.Now(),
	}

	entry := LogEntry{
		Ev:  name + ".start",
		Sid: child.sid,
		Tid: child.tid,
		Ts:  time.Now().Unix(),
	}
	for _, opt := range opts {
		opt(&entry)
	}
	writeEntry(entry)

	return child
}

// End logs the span end event with duration
func (s *Span) End() {
	dur := time.Since(s.start).Milliseconds()
	entry := LogEntry{
		Ev:  s.name + ".end",
		Sid: s.sid,
		Tid: s.tid,
		Dur: dur,
		Ts:  time.Now().Unix(),
	}
	writeEntry(entry)
}

// EndWithError logs the span end event with error
func (s *Span) EndWithError(err string) {
	dur := time.Since(s.start).Milliseconds()
	entry := LogEntry{
		Ev:  s.name + ".end",
		Sid: s.sid,
		Tid: s.tid,
		Dur: dur,
		Err: err,
		Ts:  time.Now().Unix(),
	}
	writeEntry(entry)
}
```

**Step 4: Update LogEntry struct for field ordering**

Replace the `LogEntry` struct:

```go
// LogEntry represents a single log entry
// Field order: ev, sid, tid, dur, err, msg, data, ts
type LogEntry struct {
	Ev   string         `json:"ev"`
	Sid  string         `json:"sid,omitempty"`
	Tid  string         `json:"tid,omitempty"`
	Dur  int64          `json:"dur,omitempty"`
	Err  string         `json:"err,omitempty"`
	Msg  string         `json:"msg,omitempty"`
	Data map[string]any `json:"data,omitempty"`
	Ts   int64          `json:"ts"`
}
```

**Step 5: Extract writeEntry helper from Log**

Add helper and update `Log` function:

```go
// writeEntry writes a log entry to the file
func writeEntry(entry LogEntry) error {
	mu.Lock()
	defer mu.Unlock()

	if err := ensureInit(); err != nil {
		return err
	}

	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}

	data = append(data, '\n')
	if _, err := file.Write(data); err != nil {
		return err
	}

	return file.Sync()
}

// Log writes an event to the log file
func Log(ev string, opts ...Option) error {
	entry := LogEntry{
		Ts: time.Now().Unix(),
		Ev: ev,
	}

	for _, opt := range opts {
		opt(&entry)
	}

	return writeEntry(entry)
}
```

**Step 6: Run tests**

Run: `cd /Users/r/repos/theGrid/.worktrees/simplified-logging/grid-cli && go build ./...`
Expected: Build succeeds

**Step 7: Commit**

```bash
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging add grid-cli/internal/jsonlog/jsonlog.go
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging commit -m "feat(cli): add Span type to jsonlog for hierarchical tracing"
```

---

## Task 2: Add Span Type to Server JSONLogger

**Files:**
- Modify: `grid-server/Sources/GridServer/JSONLogger.swift`

**Step 1: Add Span struct**

Add after the `JSONLogger` actor, before `jlog`:

```swift
/// Represents a timed span with start/end events
struct Span {
    let tid: String
    let sid: String
    let name: String
    let start: Date

    /// Create a child span with dot-notation sid
    func startChild(_ name: String, data: [String: Any]? = nil) async -> Span {
        let child = Span(
            tid: self.tid,
            sid: "\(self.sid).\(name)",
            name: name,
            start: Date()
        )
        await JSONLogger.shared.logSpanStart(child, data: data)
        return child
    }

    /// End the span and log duration
    func end(err: String? = nil) async {
        let dur = Int64(Date().timeIntervalSince(start) * 1000)
        await JSONLogger.shared.logSpanEnd(self, dur: dur, err: err)
    }
}
```

**Step 2: Add span logging methods to JSONLogger**

Add inside the `JSONLogger` actor, after the existing `log` methods:

```swift
    /// Start a new span (called from MessageHandler with parent context)
    func startSpan(_ name: String, tid: String, parentSid: String?, data: [String: Any]? = nil) -> Span {
        let sid = parentSid != nil ? "\(parentSid!).\(name)" : tid
        let span = Span(tid: tid, sid: sid, name: name, start: Date())

        Task {
            await logSpanStart(span, data: data)
        }

        return span
    }

    /// Log span start event
    func logSpanStart(_ span: Span, data: [String: Any]? = nil) {
        var event: [String: Any] = [:]
        // Field order: ev, sid, tid, data, ts
        event["ev"] = "\(span.name).start"
        event["sid"] = span.sid
        event["tid"] = span.tid
        if let data = data {
            event["data"] = data
        }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        writeEvent(event)
    }

    /// Log span end event with duration
    func logSpanEnd(_ span: Span, dur: Int64, err: String? = nil) {
        var event: [String: Any] = [:]
        // Field order: ev, sid, tid, dur, err, ts
        event["ev"] = "\(span.name).end"
        event["sid"] = span.sid
        event["tid"] = span.tid
        event["dur"] = dur
        if let err = err {
            event["err"] = err
        }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        writeEvent(event)
    }

    /// Write event with correct field ordering
    private func writeEvent(_ event: [String: Any]) {
        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        // Create ordered key array for field ordering
        let orderedKeys = ["ev", "sid", "tid", "dur", "err", "msg", "data", "ts"]
        var orderedPairs: [(String, Any)] = []

        for key in orderedKeys {
            if let value = event[key] {
                orderedPairs.append((key, value))
            }
        }

        // Build JSON string manually for field ordering
        var jsonParts: [String] = []
        for (key, value) in orderedPairs {
            if let strVal = value as? String {
                jsonParts.append("\"\(key)\":\"\(strVal)\"")
            } else if let intVal = value as? Int64 {
                jsonParts.append("\"\(key)\":\(intVal)")
            } else if let intVal = value as? Int {
                jsonParts.append("\"\(key)\":\(intVal)")
            } else if let dictVal = value as? [String: Any],
                      let jsonData = try? JSONSerialization.data(withJSONObject: dictVal, options: [.sortedKeys]),
                      let jsonStr = String(data: jsonData, encoding: .utf8) {
                jsonParts.append("\"\(key)\":\(jsonStr)")
            }
        }

        let line = "{" + jsonParts.joined(separator: ",") + "}\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if fileHandle == nil {
            openFileHandle()
        }

        fileHandle?.write(lineData)
        fileHandle?.synchronizeFile()
    }
```

**Step 3: Update existing log method to use writeEvent**

Replace the existing `log` method body to use ordered output:

```swift
    /// Log an event
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil, tid: String? = nil, sid: String? = nil) {
        var event: [String: Any] = [:]
        event["ev"] = ev
        if let sid = sid { event["sid"] = sid }
        if let tid = tid { event["tid"] = tid }
        if let msg = msg { event["msg"] = msg }
        if let data = data { event["data"] = data }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        writeEvent(event)
    }
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/.worktrees/simplified-logging/grid-server && swift build`
Expected: Build succeeds

**Step 5: Commit**

```bash
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging add grid-server/Sources/GridServer/JSONLogger.swift
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging commit -m "feat(server): add Span type to JSONLogger for hierarchical tracing"
```

---

## Task 3: Update CLI to Use Spans for Commands

**Files:**
- Modify: `grid-cli/cmd/grid/main.go`

**Step 1: Find cmd.start usage and replace with span**

Search for the existing `cmd.start` log and replace with span-based approach. The main command entry point should create a root span.

Look for pattern like:
```go
jsonlog.Log("cmd.start", jsonlog.WithData(map[string]any{...}))
```

Replace with:
```go
span := jsonlog.StartSpan("cmd", jsonlog.WithData(map[string]any{...}))
defer span.End()
```

**Step 2: Update trace context in client requests**

In `grid-cli/internal/client/client.go`, the `_trace` param already extracts from context. Update commands to pass span context through the request.

The existing code already handles this via `tracing.GetTraceInfo(ctx)`. We need to ensure the span's tid/sid are used.

**Step 3: Build and test**

Run: `cd /Users/r/repos/theGrid/.worktrees/simplified-logging && make build`
Expected: Build succeeds

Run: `./grid-cli/bin/thegrid focus left 2>&1; cat ~/.local/state/thegrid/thegrid-cli.json | tail -5`
Expected: See `cmd.start` and `cmd.end` events with matching `sid`/`tid` and `dur` on end

**Step 4: Commit**

```bash
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging add grid-cli/
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging commit -m "feat(cli): use spans for command timing"
```

---

## Task 4: Update Server MessageHandler to Use Spans

**Files:**
- Modify: `grid-server/Sources/GridServer/MessageHandler.swift`

**Step 1: Extract trace context from request params**

In `handle(request:completion:)`, extract `_trace` and create server span:

Replace the current span handling:
```swift
func handle(request: Request, completion: @escaping (Response) -> Void) {
    // Extract trace context from params
    var tid: String? = nil
    var parentSid: String? = nil
    if let traceInfo = request.params?["_trace"]?.value as? [String: String] {
        tid = traceInfo["tid"]
        parentSid = traceInfo["sid"]
    }

    // Create server span (or generate new trace if none provided)
    let span: Span
    if let tid = tid {
        span = JSONLogger.shared.startSpan("srv", tid: tid, parentSid: parentSid, data: ["method": request.method])
    } else {
        // No trace context - this shouldn't happen normally but handle gracefully
        let newTid = UUID().uuidString.prefix(8).lowercased()
        span = JSONLogger.shared.startSpan("srv", tid: String(newTid), parentSid: nil, data: ["method": request.method])
    }
```

**Step 2: End span on completion**

Update the completion handling to end the span:

```swift
    // Execute handler with span context
    handler(request) { response in
        Task {
            if response.error != nil {
                await span.end(err: response.error?.message)
            } else {
                await span.end()
            }
        }
        completion(response)
    }
```

**Step 3: Remove old OpenTelemetry span code**

Remove the `Tracing.getTracer()` and related OTel span code since we're replacing it with our simpler span system.

**Step 4: Build and test**

Run: `cd /Users/r/repos/theGrid/.worktrees/simplified-logging && make build && pkill -f grid-server; sleep 1; nohup ./grid-server/.build/debug/grid-server > /dev/null 2>&1 &`

Run: `sleep 1 && ./grid-cli/bin/thegrid ping && cat ~/.local/state/thegrid/thegrid-server.json | tail -5`
Expected: See `srv.start` and `srv.end` events with `sid` like `a1b2.srv` and `dur` on end

**Step 5: Commit**

```bash
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging add grid-server/Sources/GridServer/MessageHandler.swift
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging commit -m "feat(server): use spans for request handling"
```

---

## Task 5: Add Subsystem Spans (Border, State)

**Files:**
- Modify: `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift`
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Add span to SimpleBorderManager.updateFocus**

Wrap the focus update logic in a span:

```swift
func updateFocus(newFocusedWindow: UInt32) {
    Task {
        let span = await JSONLogger.shared.startSpan("border", tid: CurrentSpan.traceId ?? "unknown", parentSid: CurrentSpan.spanId, data: ["wid": newFocusedWindow])

        // ... existing focus update logic ...

        await span.end()
    }
}
```

**Step 2: Add span to StateManager.handleWindowFocused**

Similar pattern:

```swift
func handleWindowFocused(_ windowID: UInt32) {
    Task {
        let span = await JSONLogger.shared.startSpan("state", tid: CurrentSpan.traceId ?? "unknown", parentSid: CurrentSpan.spanId)

        // ... existing logic ...

        await span.end()
    }
}
```

**Step 3: Build and test**

Run: `cd /Users/r/repos/theGrid/.worktrees/simplified-logging && make build && pkill -f grid-server; sleep 1; nohup ./grid-server/.build/debug/grid-server > /dev/null 2>&1 &`

Run: `sleep 1 && ./grid-cli/bin/thegrid focus left && cat ~/.local/state/thegrid/thegrid-server.json | tail -10`
Expected: See nested spans like `a1b2.srv.border` and `a1b2.srv.state`

**Step 4: Commit**

```bash
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging add grid-server/Sources/GridServer/
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging commit -m "feat(server): add spans to border and state subsystems"
```

---

## Task 6: Update CLAUDE.md with Span Usage

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update logging section**

Add span usage examples to the logging section:

```markdown
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
```

**Step 2: Commit**

```bash
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging add CLAUDE.md
git -C /Users/r/repos/theGrid/.worktrees/simplified-logging commit -m "docs: add span-based logging usage to CLAUDE.md"
```

---

## Task 7: Manual Verification

**Step 1: Full rebuild and restart**

```bash
cd /Users/r/repos/theGrid/.worktrees/simplified-logging
make build
pkill -f grid-server
sleep 1
nohup ./grid-server/.build/debug/grid-server > /dev/null 2>&1 &
sleep 1
```

**Step 2: Clear logs and run test command**

```bash
> ~/.local/state/thegrid/thegrid-cli.json
> ~/.local/state/thegrid/thegrid-server.json
./grid-cli/bin/thegrid focus left
```

**Step 3: Verify CLI log**

```bash
cat ~/.local/state/thegrid/thegrid-cli.json
```

Expected output pattern:
```jsonl
{"ev":"cmd.start","sid":"xxxx","tid":"xxxx","data":{"cmd":"focus","dir":"left"},"ts":...}
{"ev":"cmd.end","sid":"xxxx","tid":"xxxx","dur":NN,"ts":...}
```

**Step 4: Verify server log**

```bash
cat ~/.local/state/thegrid/thegrid-server.json
```

Expected output pattern:
```jsonl
{"ev":"srv.start","sid":"xxxx.srv","tid":"xxxx","data":{"method":"window.focus"},"ts":...}
{"ev":"state.start","sid":"xxxx.srv.state","tid":"xxxx","ts":...}
{"ev":"state.end","sid":"xxxx.srv.state","tid":"xxxx","dur":N,"ts":...}
{"ev":"border.start","sid":"xxxx.srv.border","tid":"xxxx","data":{"wid":123},"ts":...}
{"ev":"border.end","sid":"xxxx.srv.border","tid":"xxxx","dur":N,"ts":...}
{"ev":"srv.end","sid":"xxxx.srv","tid":"xxxx","dur":NN,"ts":...}
```

**Step 5: Verify trace correlation**

```bash
# Extract a trace ID from CLI log
TID=$(cat ~/.local/state/thegrid/thegrid-cli.json | head -1 | jq -r '.tid')
echo "Trace ID: $TID"

# Find all events with this trace ID across both logs
grep "\"tid\":\"$TID\"" ~/.local/state/thegrid/*.json
```

Expected: All events from both CLI and server logs with same `tid`
