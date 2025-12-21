package tracing

import (
	"context"
)

// Span interface matches jsonlog.Span methods we need
type Span interface {
	Tid() string
	Sid() string
}

var currentSpan Span

// SetCurrentSpan sets the current command span
func SetCurrentSpan(span Span) {
	currentSpan = span
}

// GetTraceInfo returns the current span's trace and span IDs
// Returns empty strings if no span is set
func GetTraceInfo(ctx context.Context) (traceID, spanID string) {
	if currentSpan == nil {
		return "", ""
	}
	return currentSpan.Tid(), currentSpan.Sid()
}
