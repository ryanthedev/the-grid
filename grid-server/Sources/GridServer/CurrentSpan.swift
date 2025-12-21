import Foundation

enum CurrentSpan {
    @TaskLocal static var current: Span?

    static var traceId: String? {
        return current?.tid
    }

    static var spanId: String? {
        return current?.sid
    }
}
