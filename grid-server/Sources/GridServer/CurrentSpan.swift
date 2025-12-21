import Foundation
import OpenTelemetryApi

enum CurrentSpan {
    @TaskLocal static var current: Span?

    static var traceId: String? {
        guard let span = current else { return nil }
        return String(span.context.traceId.hexString.prefix(8))
    }

    static var spanId: String? {
        guard let span = current else { return nil }
        return String(span.context.spanId.hexString.prefix(8))
    }
}
