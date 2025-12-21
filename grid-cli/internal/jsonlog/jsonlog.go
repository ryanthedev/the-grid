// Package jsonlog provides JSONL logging to ~/.local/state/thegrid/thegrid-cli.json
package jsonlog

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
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
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%x", time.Now().UnixNano())[:4]
	}
	for i := range b {
		b[i] = chars[b[i]%byte(len(chars))]
	}
	return string(b)
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

// StartSpan creates a new root span and logs the start event
func StartSpan(name string, opts ...Option) *Span {
	if name == "" {
		name = "span"
	}
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
	if err := writeEntry(entry); err != nil {
		fmt.Fprintf(os.Stderr, "jsonlog: failed to write span start: %v\n", err)
	}

	return span
}

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
	if err := writeEntry(entry); err != nil {
		fmt.Fprintf(os.Stderr, "jsonlog: failed to write child span start: %v\n", err)
	}

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
	if err := writeEntry(entry); err != nil {
		fmt.Fprintf(os.Stderr, "jsonlog: failed to write span end: %v\n", err)
	}
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
	if err := writeEntry(entry); err != nil {
		fmt.Fprintf(os.Stderr, "jsonlog: failed to write span end with error: %v\n", err)
	}
}

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
