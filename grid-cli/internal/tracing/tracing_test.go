package tracing

import (
	"context"
	"testing"
)

// mockSpan implements the Span interface for testing
type mockSpan struct {
	tid string
	sid string
}

func (m *mockSpan) Tid() string { return m.tid }
func (m *mockSpan) Sid() string { return m.sid }

func TestGetTraceInfo_NoSpan(t *testing.T) {
	// Clear any existing span
	SetCurrentSpan(nil)
	ctx := context.Background()

	tid, sid := GetTraceInfo(ctx)
	if tid != "" || sid != "" {
		t.Errorf("Expected empty trace info without span, got tid=%s, sid=%s", tid, sid)
	}
}

func TestGetTraceInfo_WithSpan(t *testing.T) {
	ctx := context.Background()

	span := &mockSpan{
		tid: "test-trace-id-1234567890abcdef",
		sid: "test-span-12345",
	}
	SetCurrentSpan(span)
	defer SetCurrentSpan(nil)

	tid, sid := GetTraceInfo(ctx)
	if tid != "test-trace-id-1234567890abcdef" {
		t.Errorf("Expected tid='test-trace-id-1234567890abcdef', got %s", tid)
	}
	if sid != "test-span-12345" {
		t.Errorf("Expected sid='test-span-12345', got %s", sid)
	}
}

func TestSetCurrentSpan(t *testing.T) {
	span1 := &mockSpan{tid: "tid1", sid: "sid1"}
	span2 := &mockSpan{tid: "tid2", sid: "sid2"}

	SetCurrentSpan(span1)
	tid, sid := GetTraceInfo(context.Background())
	if tid != "tid1" || sid != "sid1" {
		t.Errorf("Expected tid1/sid1, got %s/%s", tid, sid)
	}

	SetCurrentSpan(span2)
	tid, sid = GetTraceInfo(context.Background())
	if tid != "tid2" || sid != "sid2" {
		t.Errorf("Expected tid2/sid2, got %s/%s", tid, sid)
	}

	SetCurrentSpan(nil)
	tid, sid = GetTraceInfo(context.Background())
	if tid != "" || sid != "" {
		t.Errorf("Expected empty after nil, got %s/%s", tid, sid)
	}
}
