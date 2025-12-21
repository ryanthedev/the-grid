# Simplified Logging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace multi-file logging with two JSONL files and remove debug flags.

**Architecture:** Single JSON logger per component (CLI and server) writing JSONL to dedicated files. No log levels, no rotation, no console output from server except log path on startup.

**Tech Stack:** Go (CLI), Swift (server), JSONL format

---

## Task 1: Create CLI JSONLogger

**Files:**
- Create: `grid-cli/internal/jsonlog/jsonlog.go`
- Test: `grid-cli/internal/jsonlog/jsonlog_test.go`

**Step 1: Create the jsonlog package**

Create `grid-cli/internal/jsonlog/jsonlog.go`:

```go
// Package jsonlog provides JSONL logging to ~/.local/state/thegrid/thegrid-cli.json
package jsonlog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	stateDir = ".local/state/thegrid"
	logFile  = "thegrid-cli.json"
)

var (
	mu      sync.Mutex
	file    *os.File
	inited  bool
)

// LogEntry represents a single log entry
type LogEntry struct {
	Ts   int64          `json:"ts"`
	Ev   string         `json:"ev"`
	Msg  string         `json:"msg,omitempty"`
	Data map[string]any `json:"data,omitempty"`
	Tid  string         `json:"tid,omitempty"`
	Sid  string         `json:"sid,omitempty"`
}

// Option configures a log entry
type Option func(*LogEntry)

// WithMsg adds a message to the log entry
func WithMsg(msg string) Option {
	return func(e *LogEntry) {
		e.Msg = msg
	}
}

// WithData adds data to the log entry
func WithData(data map[string]any) Option {
	return func(e *LogEntry) {
		e.Data = data
	}
}

// WithTrace adds trace context to the log entry
func WithTrace(tid, sid string) Option {
	return func(e *LogEntry) {
		e.Tid = tid
		e.Sid = sid
	}
}

// GetLogPath returns the full path to the log file
func GetLogPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, stateDir, logFile)
}

func ensureInit() error {
	if inited {
		return nil
	}

	path := GetLogPath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	file = f
	inited = true
	return nil
}

// Log writes an event to the log file
func Log(ev string, opts ...Option) error {
	mu.Lock()
	defer mu.Unlock()

	if err := ensureInit(); err != nil {
		return err
	}

	entry := LogEntry{
		Ts: time.Now().Unix(),
		Ev: ev,
	}

	for _, opt := range opts {
		opt(&entry)
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

// Close closes the log file
func Close() error {
	mu.Lock()
	defer mu.Unlock()

	if file != nil {
		err := file.Close()
		file = nil
		inited = false
		return err
	}
	return nil
}
```

**Step 2: Create minimal test**

Create `grid-cli/internal/jsonlog/jsonlog_test.go`:

```go
package jsonlog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestLog(t *testing.T) {
	// Use temp dir for test
	tmpDir := t.TempDir()
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", tmpDir)
	defer os.Setenv("HOME", origHome)

	// Reset state
	mu.Lock()
	file = nil
	inited = false
	mu.Unlock()

	// Log an event
	err := Log("test.event", WithMsg("hello"), WithData(map[string]any{"key": "value"}))
	if err != nil {
		t.Fatalf("Log failed: %v", err)
	}
	Close()

	// Read and verify
	path := filepath.Join(tmpDir, stateDir, logFile)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}

	var entry LogEntry
	if err := json.Unmarshal(data[:len(data)-1], &entry); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}

	if entry.Ev != "test.event" {
		t.Errorf("expected ev=test.event, got %s", entry.Ev)
	}
	if entry.Msg != "hello" {
		t.Errorf("expected msg=hello, got %s", entry.Msg)
	}
}
```

**Step 3: Run tests**

Run: `cd grid-cli && go test ./internal/jsonlog/...`
Expected: PASS

**Step 4: Commit**

```bash
git add grid-cli/internal/jsonlog/
git commit -m "feat(cli): add jsonlog package for simplified logging"
```

---

## Task 2: Create Server JSONLogger

**Files:**
- Create: `grid-server/Sources/GridServer/JSONLogger.swift`

**Step 1: Create JSONLogger actor**

Create `grid-server/Sources/GridServer/JSONLogger.swift`:

```swift
import Foundation

/// Thread-safe JSON logger that writes to ~/.local/state/thegrid/thegrid-server.json
actor JSONLogger {
    static let shared = JSONLogger()

    private let filePath: String
    private var fileHandle: FileHandle?
    private var isInitialized = false

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(homeDir)/.local/state/thegrid"
        self.filePath = "\(logDir)/thegrid-server.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    /// Get the log file path (for startup message)
    nonisolated func getLogPath() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.local/state/thegrid/thegrid-server.json"
    }

    /// Log an event
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil, tid: String? = nil, sid: String? = nil) {
        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        var event: [String: Any] = [
            "ts": Int64(Date().timeIntervalSince1970),
            "ev": ev
        ]

        if let msg = msg {
            event["msg"] = msg
        }
        if let data = data {
            event["data"] = data
        }
        if let tid = tid {
            event["tid"] = tid
        }
        if let sid = sid {
            event["sid"] = sid
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let line = jsonString + "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if fileHandle == nil {
            openFileHandle()
        }

        fileHandle?.write(lineData)
        fileHandle?.synchronizeFile()
    }

    /// Log with trace context from CurrentSpan
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
        let tid = CurrentSpan.traceId
        let sid = CurrentSpan.spanId
        Task { await self.log(ev, msg: msg, data: data, tid: tid, sid: sid) }
    }

    private func openFileHandle() {
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        }
        fileHandle = FileHandle(forUpdatingAtPath: filePath)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }
}

/// Convenience function for non-async contexts
func jlog(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
    let tid = CurrentSpan.traceId
    let sid = CurrentSpan.spanId
    Task { await JSONLogger.shared.log(ev, msg: msg, data: data, tid: tid, sid: sid) }
}
```

**Step 2: Build to verify syntax**

Run: `cd grid-server && swift build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add grid-server/Sources/GridServer/JSONLogger.swift
git commit -m "feat(server): add JSONLogger for simplified logging"
```

---

## Task 3: Migrate CLI to JSONLogger

**Files:**
- Modify: `grid-cli/cmd/grid/main.go`
- Delete: `grid-cli/internal/eventlog/eventlog.go`
- Delete: `grid-cli/internal/eventlog/eventlog_test.go`
- Delete: `grid-cli/internal/eventlog/example_test.go`
- Delete: `grid-cli/internal/logging/logging.go`

**Step 1: Update main.go imports and remove debug flag**

In `grid-cli/cmd/grid/main.go`:
- Replace import `"github.com/yourusername/grid-cli/internal/eventlog"` with `"github.com/yourusername/grid-cli/internal/jsonlog"`
- Remove import `"github.com/yourusername/grid-cli/internal/logging"`
- Remove `debugMode bool` variable (line 40)
- Remove `--debug` flag registration (line 2642)
- Remove `logging.SetDebug(true)` call (line 2809)
- Remove `logging.Init()` and `logging.Close()` calls (lines 2816-2817)

**Step 2: Replace eventlog.Log calls with jsonlog.Log**

Replace all `eventlog.Log("ev", map[string]any{...})` with:
```go
jsonlog.Log("ev", jsonlog.WithData(map[string]any{...}))
```

In `cmd/grid/main.go` (PersistentPreRun around line 82):
```go
jsonlog.Log("cmd.start", jsonlog.WithData(map[string]any{
    "cmd":  cmd.CommandPath(),
    "args": argsMap,
    "rid":  currentRequestID,
}))
```

**Step 3: Replace logging.Error/Warn/Info/Debug calls**

In `internal/layout/apply.go`, `internal/reconcile/reconcile.go`, `internal/window/move.go`:

Convert patterns like:
```go
logging.Debug().Bool("extend", extend).Msg("cross-monitor focus enabled")
```

To:
```go
jsonlog.Log("focus.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
```

Convert patterns like:
```go
logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to load state")
```

To:
```go
jsonlog.Log("err.focus_next", jsonlog.WithMsg("failed to load state"), jsonlog.WithData(map[string]any{"err": err.Error()}))
```

**Step 4: Delete old logging packages**

```bash
rm -rf grid-cli/internal/eventlog/
rm grid-cli/internal/logging/logging.go
```

**Step 5: Update go.mod to remove zerolog dependency (if no longer used)**

Run: `cd grid-cli && go mod tidy`

**Step 6: Build and test**

Run: `cd grid-cli && go build ./... && go test ./...`
Expected: Build and tests pass

**Step 7: Commit**

```bash
git add -A
git commit -m "refactor(cli): migrate to jsonlog, remove debug flag and zerolog"
```

---

## Task 4: Migrate Server to JSONLogger

**Files:**
- Modify: `grid-server/Sources/GridServer/main.swift`
- Modify: All files using `EventLog.shared.log()`
- Delete: `grid-server/Sources/GridServer/EventLog.swift`

**Step 1: Update main.swift**

Remove `--verbose` and `--debug` flags (lines 33-37).

Replace server startup to only print log path:

```swift
func run() throws {
    // Print log path (only console output)
    print("logging to \(JSONLogger.shared.getLogPath())")

    // Silence all other console output
    LoggingSystem.bootstrap { _ in SilentLogHandler() }

    // Initialize OpenTelemetry tracing
    Tracing.initialize()

    // Log server start
    jlog("srv.start", data: ["ver": "0.1.0", "socket": socketPath])

    // ... rest of run() unchanged except log() calls become jlog() calls
}
```

**Step 2: Replace all log() and EventLog.shared.log() calls**

Replace the helper function at top:
```swift
// Delete this:
func log(_ event: String, _ data: [String: Any] = [:]) {
    Task { await EventLog.shared.log(event, data) }
}
```

Replace with calls to `jlog()` throughout main.swift.

**Step 3: Update all other files**

For each file in `Sources/GridServer/` that uses `EventLog.shared.log`:

Replace:
```swift
await EventLog.shared.log("event.code", ["key": value])
```

With:
```swift
await JSONLogger.shared.log("event.code", data: ["key": value])
```

Or for non-async contexts:
```swift
jlog("event.code", data: ["key": value])
```

Files to update:
- `ApplicationObserver.swift`
- `AutoLayout/AutoLayoutManager.swift`
- `BFD/BFDKeyHandler.swift`
- `BFD/BFDManager.swift`
- `Borders/BorderEvents.swift`
- `Borders/BorderWindow.swift`
- `Borders/SimpleBorderConfig.swift`
- `Borders/SimpleBorderManager.swift`
- `EdgeDetector.swift`
- `EventBroadcaster.swift`
- `MessageHandler.swift`
- `MouseHandler.swift`
- `MSSClient.swift`
- `PermissionChecker.swift`
- `ResizeManager.swift`
- `ResizeOverlay.swift`
- `SocketServer.swift`
- `StateManager.swift`
- `WindowManipulator.swift`
- `WorkspaceObserver.swift`

**Step 4: Delete old EventLog**

```bash
rm grid-server/Sources/GridServer/EventLog.swift
```

**Step 5: Build**

Run: `cd grid-server && swift build`
Expected: Build succeeds

**Step 6: Commit**

```bash
git add -A
git commit -m "refactor(server): migrate to JSONLogger, remove debug flags"
```

---

## Task 5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update logging documentation**

Replace the Logging Requirements section with:

```markdown
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
```

Update Project Paths section:
```markdown
## Project Paths
- **Log files**: `~/.local/state/thegrid/`
  - `thegrid-cli.json` - CLI logs (JSONL)
  - `thegrid-server.json` - Server logs (JSONL)
  - `state.json` - Runtime state
```

Remove references to `events.jsonl`, `grid-cli.log`, `grid-server.log`.

Update "Full rebuild and restart" to remove `--debug`:
```bash
make build && pkill -f grid-server && sleep 1 && \
  nohup ./grid-server/.build/debug/grid-server > /dev/null 2>&1 &
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for simplified logging"
```

---

## Task 6: Clean Up Old Log Files

**Files:**
- None (runtime cleanup)

**Step 1: Document cleanup command**

Users can clean up old files with:
```bash
rm -f ~/.local/state/thegrid/events.jsonl
rm -f ~/.local/state/thegrid/grid-cli.log
rm -f ~/.local/state/thegrid/grid-server.log
```

**Step 2: Final build and test**

```bash
make build
./grid-cli/bin/thegrid ping
cat ~/.local/state/thegrid/thegrid-cli.json | tail -3
```

Expected: Ping succeeds, log file shows JSONL entries.

**Step 3: Final commit**

```bash
git add -A
git commit -m "chore: final cleanup for simplified logging"
```
