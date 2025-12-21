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
	mu     sync.Mutex
	file   *os.File
	inited bool
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
