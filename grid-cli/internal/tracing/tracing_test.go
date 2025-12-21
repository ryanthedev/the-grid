package tracing

import (
	"context"
	"testing"
)

func TestInit(t *testing.T) {
	Init()
	if tracer == nil {
		t.Fatal("tracer should not be nil after Init()")
	}
}

func TestTracer(t *testing.T) {
	Init()
	tr := Tracer()
	if tr == nil {
		t.Fatal("Tracer() should not return nil")
	}
}

func TestGetTraceInfo(t *testing.T) {
	Init()
	ctx := context.Background()

	// Without span, should return empty strings
	tid, sid := GetTraceInfo(ctx)
	if tid != "" || sid != "" {
		t.Errorf("Expected empty trace info without span, got tid=%s, sid=%s", tid, sid)
	}

	// With span, should return valid IDs
	ctx, span := Tracer().Start(ctx, "test-span")
	defer span.End()

	tid, sid = GetTraceInfo(ctx)
	if tid == "" {
		t.Error("Expected non-empty trace ID")
	}
	if sid == "" {
		t.Error("Expected non-empty span ID")
	}

	// Verify IDs are hex strings of correct length
	if len(tid) != 32 {
		t.Errorf("Expected trace ID length 32, got %d", len(tid))
	}
	if len(sid) != 16 {
		t.Errorf("Expected span ID length 16, got %d", len(sid))
	}
}
