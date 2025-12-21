import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

enum Tracing {
    private static var tracer: Tracer!

    static func initialize() {
        let tracerProvider = TracerProviderBuilder().build()
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        tracer = OpenTelemetry.instance.tracerProvider.get(
            instrumentationName: "thegrid-server",
            instrumentationVersion: "1.0.0"
        )
    }

    static func getTracer() -> Tracer {
        return tracer
    }

    static func extractContext(from params: [String: AnyCodable]?) -> SpanContext? {
        guard let trace = params?["_trace"]?.value as? [String: String],
              let tidStr = trace["tid"],
              let sidStr = trace["sid"] else {
            return nil
        }
        let traceId = TraceId(fromHexString: tidStr)
        let spanId = SpanId(fromHexString: sidStr)
        return SpanContext.createFromRemoteParent(
            traceId: traceId,
            spanId: spanId,
            traceFlags: TraceFlags(),
            traceState: TraceState()
        )
    }
}
