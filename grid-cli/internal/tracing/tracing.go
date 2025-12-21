package tracing

import (
	"context"

	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	oteltrace "go.opentelemetry.io/otel/trace"
)

var tracer oteltrace.Tracer

// Init initializes the OpenTelemetry tracer provider
// No exporter is configured - we only need trace/span ID generation
func Init() {
	tp := sdktrace.NewTracerProvider()
	otel.SetTracerProvider(tp)
	tracer = tp.Tracer("thegrid-cli")
}

// Tracer returns the configured tracer for creating spans
func Tracer() oteltrace.Tracer {
	return tracer
}

// GetTraceInfo extracts trace and span IDs from the context
// Returns empty strings if no valid span context is found
func GetTraceInfo(ctx context.Context) (traceID, spanID string) {
	span := oteltrace.SpanFromContext(ctx)
	sc := span.SpanContext()
	if !sc.IsValid() {
		return "", ""
	}
	return sc.TraceID().String(), sc.SpanID().String()
}
