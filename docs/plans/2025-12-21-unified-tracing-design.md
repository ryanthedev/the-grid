# Unified Tracing Design

## Status

| Phase | Status | Commit |
|-------|--------|--------|
| Phase 1: Swift server-side enrichment | ✅ Complete | `7f99162` |
| Phase 2: Go CLI trace injection | ✅ Complete | `79397f0` |
| Phase 3: Async operation propagation | ⏳ Pending | - |

## Overview

Enrich existing logs with trace/span IDs using OpenTelemetry for context propagation. Like Serilog's enrichment pattern - no exporters, no collectors, just IDs in logs.

## What's Working

CLI commands now generate trace IDs and inject them into server requests. Server extracts these and enriches all logs with `tid`/`sid` fields:

```json
{"t":1766311642,"ev":"msg.handle","method":"ping","rid":"...","tid":"3c42140f","sid":"a8c9c75d"}
```

## Architecture

```
CLI (Go)                              Server (Swift)
─────────                             ──────────────
1. Create span for command
2. Get traceId/spanId from context
3. Pass in request._trace ──────────→ 4. Extract trace context
                                      5. Create child span, set CurrentSpan
                                      6. All logs auto-enriched with tid/sid
                                      7. Send response
8. End span ←─────────────────────────
```

## Completed Implementation

### Go CLI (`grid-cli/`)

**Files created:**
- `internal/tracing/tracing.go` - Init, Tracer, GetTraceInfo helpers
- `internal/tracing/tracing_test.go` - Unit tests

**Files modified:**
- `cmd/grid/main.go` - Added spans to 34 commands
- `internal/client/client.go` - Injects `_trace` into all requests
- `go.mod` - Added otel dependencies

### Swift Server (`grid-server/`)

**Files created:**
- `Sources/GridServer/Tracing.swift` - Initialize tracer, extractContext helper
- `Sources/GridServer/CurrentSpan.swift` - @TaskLocal span storage

**Files modified:**
- `Package.swift` - Added opentelemetry-swift-core dependency
- `Sources/GridServer/EventLog.swift` - Auto-enriches with tid/sid from CurrentSpan
- `Sources/GridServer/MessageHandler.swift` - Creates spans, sets CurrentSpan
- `Sources/GridServer/main.swift` - Calls Tracing.initialize()

---

## Remaining Work: Phase 3

### Goal

Propagate trace context through async operations so sub-operations (border updates, state changes) get the trace ID and appear in logs with the same `tid`.

Currently, only `msg.handle` events have trace IDs. Border and state events fired from within handlers don't inherit the trace context because they run in separate async contexts.

### Files to Modify

**1. SimpleBorderManager.swift**

Add optional span parameter to methods that are called from MessageHandler:

```swift
// Current signature
func updateFocus(newFocusedWindow: UInt32)

// New signature
func updateFocus(newFocusedWindow: UInt32, span: Span? = nil)

// Implementation
func updateFocus(newFocusedWindow: UInt32, span: Span? = nil) {
    // Wrap work in span context so EventLog picks up tid/sid
    let work = {
        // existing implementation
    }

    if let span = span {
        CurrentSpan.$current.withValue(span) {
            work()
        }
    } else {
        work()
    }
}
```

Methods to update:
- `updateFocus(newFocusedWindow:)`
- `setCellAssignments(_:forDisplay:)`
- `setCellBounds(_:forDisplay:)`

**2. StateManager.swift**

Similar pattern:

```swift
// Current
func handleWindowFocused(_ windowID: UInt32)

// New
func handleWindowFocused(_ windowID: UInt32, span: Span? = nil)
```

Methods to update:
- `handleWindowFocused(_:)`
- `updateState()`

**3. MessageHandler.swift**

Pass the span to async operations:

```swift
// In window.focus handler, around line 579
self.simpleBorderManager?.updateFocus(newFocusedWindow: wid, span: span)
StateManager.shared.handleWindowFocused(wid, span: span)
```

### Testing Phase 3

```bash
# Run focus command
./grid-cli/bin/thegrid focus left

# Check for multiple events with same tid
TID=$(grep "msg.handle" ~/.local/state/thegrid/events.jsonl | tail -1 | jq -r .tid)
grep "$TID" ~/.local/state/thegrid/events.jsonl | jq .ev
# Should show: msg.handle, bdr.*, state.*, etc. all with same tid
```

---

## Usage

```bash
# Find all events for a trace
grep "3c42140f" ~/.local/state/thegrid/events.jsonl

# With jq
jq 'select(.tid == "3c42140f")' ~/.local/state/thegrid/events.jsonl

# Find slow commands
jq 'select(.ev == "msg.handle") | {method, tid}' ~/.local/state/thegrid/events.jsonl
```

## Future: Add Visualization

When ready for Jaeger/Zipkin, add exporter to server:

```swift
// In Tracing.initialize()
let jaegerExporter = OtlpGrpcSpanExporter(endpoint: "localhost:4317")
let tracerProvider = TracerProviderBuilder()
    .add(spanProcessor: SimpleSpanProcessor(spanExporter: jaegerExporter))
    .build()
```

No other code changes needed.
