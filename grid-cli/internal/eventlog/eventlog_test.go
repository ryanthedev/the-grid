package eventlog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// setupTest creates a temp directory and overrides HOME for isolated testing
func setupTest(t *testing.T) (cleanup func()) {
	tmpDir := t.TempDir()

	// Override HOME env var
	oldHome := os.Getenv("HOME")
	os.Setenv("HOME", tmpDir)

	// Reset global state
	mu.Lock()
	if logFile != nil {
		logFile.Close()
	}
	logFile = nil
	inited = false
	mu.Unlock()

	return func() {
		os.Setenv("HOME", oldHome)
		Close()
	}
}

func TestLog(t *testing.T) {
	cleanup := setupTest(t)
	defer cleanup()

	logPath := GetEventLogPath()

	// Test logging an event
	err := Log("cmd.start", map[string]any{
		"cmd":  "focus",
		"args": map[string]string{"dir": "east"},
		"rid":  "a1b2",
	})
	if err != nil {
		t.Fatalf("Log failed: %v", err)
	}

	// Read and verify the log file
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("Failed to read log file: %v", err)
	}

	// Parse the JSON line
	var event map[string]any
	if err := json.Unmarshal(data, &event); err != nil {
		t.Fatalf("Failed to parse JSON: %v", err)
	}

	// Verify fields
	if event["ev"] != "cmd.start" {
		t.Errorf("Expected ev=cmd.start, got %v", event["ev"])
	}
	if event["cmd"] != "focus" {
		t.Errorf("Expected cmd=focus, got %v", event["cmd"])
	}
	if event["rid"] != "a1b2" {
		t.Errorf("Expected rid=a1b2, got %v", event["rid"])
	}
	if _, ok := event["t"]; !ok {
		t.Error("Expected timestamp field 't'")
	}
}

func TestRotation(t *testing.T) {
	cleanup := setupTest(t)
	defer cleanup()

	logPath := GetEventLogPath()

	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(logPath), 0755); err != nil {
		t.Fatalf("Failed to create directory: %v", err)
	}

	// Create a large file (> 1MB)
	largeData := make([]byte, MaxFileSize+1)
	if err := os.WriteFile(logPath, largeData, 0644); err != nil {
		t.Fatalf("Failed to create large file: %v", err)
	}

	// Log an event - should trigger rotation
	err := Log("test.event", map[string]any{"msg": "after rotation"})
	if err != nil {
		t.Fatalf("Log failed: %v", err)
	}

	// Verify file was rotated (should be small)
	stat, err := os.Stat(logPath)
	if err != nil {
		t.Fatalf("Failed to stat log file: %v", err)
	}

	if stat.Size() > 1000 {
		t.Errorf("Expected file to be rotated and small, got size %d", stat.Size())
	}
}

func TestMultipleEvents(t *testing.T) {
	cleanup := setupTest(t)
	defer cleanup()

	logPath := GetEventLogPath()

	// Log multiple events
	events := []struct {
		eventType string
		data      map[string]any
	}{
		{"cmd.start", map[string]any{"cmd": "focus", "rid": "1"}},
		{"cmd.end", map[string]any{"cmd": "focus", "rid": "1", "status": "ok"}},
		{"cmd.start", map[string]any{"cmd": "swap", "rid": "2"}},
	}

	for _, ev := range events {
		if err := Log(ev.eventType, ev.data); err != nil {
			t.Fatalf("Log failed: %v", err)
		}
	}

	// Read and verify all events were written
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("Failed to read log file: %v", err)
	}

	// Count newlines (each event is one line)
	lines := 0
	for _, b := range data {
		if b == '\n' {
			lines++
		}
	}

	if lines != 3 {
		t.Errorf("Expected 3 events, got %d", lines)
	}
}
