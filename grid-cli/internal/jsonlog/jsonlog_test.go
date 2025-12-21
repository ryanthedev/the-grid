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
