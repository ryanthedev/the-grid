// Package eventlog provides thread-safe append-only event logging for debugging and post-mortem analysis.
//
// Events are written to ~/.local/state/thegrid/events.jsonl in compact JSON-lines format.
// The file is automatically rotated when it exceeds 1MB.
//
// Usage:
//
//	eventlog.Log("cmd.start", map[string]any{
//		"cmd":  "focus",
//		"args": map[string]string{"dir": "east"},
//		"rid":  "a1b2",
//	})
//
// Output format:
//
//	{"t":1702840000,"ev":"cmd.start","cmd":"focus","args":{"dir":"east"},"rid":"a1b2"}
package eventlog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	// DefaultStateDir is the directory under $HOME for event files
	DefaultStateDir = ".local/state/thegrid"
	// DefaultEventFile is the event log file name
	DefaultEventFile = "events.jsonl"
	// MaxFileSize is the size at which we truncate the log (1MB)
	MaxFileSize = 1024 * 1024
)

var (
	mu      sync.Mutex
	logFile *os.File
	inited  bool
)

// GetEventLogPath returns the full path to the event log file
func GetEventLogPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, DefaultStateDir, DefaultEventFile)
}

// ensureInit performs lazy initialization of the event log
func ensureInit() error {
	if inited {
		return nil
	}

	path := GetEventLogPath()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	// Check if file needs rotation
	if stat, err := os.Stat(path); err == nil && stat.Size() > MaxFileSize {
		// Truncate by removing the file
		os.Remove(path)
	}

	// Open file for append (create if doesn't exist)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	logFile = f
	inited = true
	return nil
}

// Log writes an event to the event log
// eventType is the event identifier (e.g., "cmd.start", "cmd.end")
// data is a map of additional fields to include in the event
func Log(eventType string, data map[string]any) error {
	mu.Lock()
	defer mu.Unlock()

	// Lazy init on first use
	if err := ensureInit(); err != nil {
		return err
	}

	// Build event object
	event := make(map[string]any)
	event["t"] = time.Now().Unix()
	event["ev"] = eventType

	// Merge additional fields
	for k, v := range data {
		event[k] = v
	}

	// Encode as compact JSON
	eventJSON, err := json.Marshal(event)
	if err != nil {
		return err
	}

	// Append newline for JSONL format
	eventJSON = append(eventJSON, '\n')

	// Write to file
	if _, err := logFile.Write(eventJSON); err != nil {
		return err
	}

	// Sync to disk (important for post-mortem debugging)
	return logFile.Sync()
}

// Close closes the event log file
func Close() error {
	mu.Lock()
	defer mu.Unlock()

	if logFile != nil {
		err := logFile.Close()
		logFile = nil
		inited = false
		return err
	}
	return nil
}
