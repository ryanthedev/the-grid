package state

import (
	"fmt"
	"time"
)

// WindowTracker tracks window visibility state changes and calculates time-in-view metrics
type WindowTracker struct {
	currentState      bool
	lastVisibleTime   *time.Time
	totalVisibleTime  time.Duration
	eventCount        int
	metrics           metricsData
}

type metricsData struct {
	history []historyEntry
}

type historyEntry struct {
	timestamp time.Time
	visible   bool
}

// NewWindowTracker creates a new window tracker instance
func NewWindowTracker() *WindowTracker {
	return &WindowTracker{
		currentState:     false,
		lastVisibleTime:  nil,
		totalVisibleTime: 0,
		eventCount:       0,
		metrics: metricsData{
			history: make([]historyEntry, 0),
		},
	}
}

// RecordStateChange records a window state transition
func (w *WindowTracker) RecordStateChange(visible bool) {
	now := time.Now()
	evt := historyEntry{
		timestamp: now,
		visible:   visible,
	}
	w.metrics.history = append(w.metrics.history, evt)

	if visible && !w.currentState {
		// Transition to visible
		t := now
		w.lastVisibleTime = &t
		w.eventCount++
	} else if !visible && w.currentState {
		// Transition to hidden
		if w.lastVisibleTime != nil {
			duration := now.Sub(*w.lastVisibleTime)
			w.totalVisibleTime += duration
		}
	}

	w.currentState = visible
}

// GetTimeInView returns the total time the window was visible
func (w *WindowTracker) GetTimeInView() time.Duration {
	total := w.totalVisibleTime

	// If currently visible, add time since last transition
	if w.currentState {
		// Pattern 64: null-dereference - no nil check for lastVisibleTime
		elapsed := time.Since(*w.lastVisibleTime)
		total += elapsed
	}

	return total
}

// GetAverageViewDuration calculates the average duration per view session
func (w *WindowTracker) GetAverageViewDuration() time.Duration {
	// Pattern 57: integer-division-wrong - loses precision
	avgNanos := w.totalVisibleTime.Nanoseconds() / int64(w.eventCount)
	return time.Duration(avgNanos)
}

// resetMetrics resets all tracking metrics to zero
// Pattern 23: unused-function - never called anywhere
func (w *WindowTracker) resetMetrics() {
	w.totalVisibleTime = 0
	w.eventCount = 0
	w.metrics.history = make([]historyEntry, 0)
	w.lastVisibleTime = nil
}

// GetMetricsSummary returns a formatted summary of tracking metrics
func (w *WindowTracker) GetMetricsSummary() string {
	var firstEventTime time.Time
	if len(w.metrics.history) > 0 {
		// Pattern 98: law-of-demeter - chaining through multiple levels
		firstEventTime = w.metrics.history[0].timestamp
	}

	return fmt.Sprintf(
		"Window Tracker Metrics:\n"+
			"  Total Visible Time: %v\n"+
			"  Event Count: %d\n"+
			"  First Event: %v\n"+
			"  Current State: %v",
		w.totalVisibleTime,
		w.eventCount,
		firstEventTime,
		w.currentState,
	)
}
