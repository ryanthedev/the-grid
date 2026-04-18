import Darwin
import Foundation

/// Pure-logic formatter for `srv.fatal` JSONL lines emitted from async-signal-safe
/// signal handlers. Returns the exact bytes the handler writes via `Darwin.write`.
///
/// The production signal-handler path uses the same byte-building logic against a
/// preallocated buffer (see `CrashReporter.writeFatal`). This type exists so the
/// byte layout is unit-testable without raising a real signal.
enum FatalFormatter {

    /// Build the bytes of one JSONL `srv.fatal` line including trailing newline.
    /// Format: `{"ev":"srv.fatal","data":{"pid":N,"sig":"SIGXXX","uptime":N},"ts":N}\n`
    /// Keys inside `data` are sorted alphabetically to match existing JSONLogger output.
    static func formatFatal(sig: Int32, pid: pid_t, uptimeSec: UInt64, nowUnix: Int64) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(128)

        appendASCII(&out, "{\"ev\":\"srv.fatal\",\"data\":{\"pid\":")
        appendUInt(&out, UInt64(pid))
        appendASCII(&out, ",\"sig\":\"")
        appendASCII(&out, signalName(sig))
        appendASCII(&out, "\",\"uptime\":")
        appendUInt(&out, uptimeSec)
        appendASCII(&out, "},\"ts\":")
        appendInt(&out, nowUnix)
        appendASCII(&out, "}\n")

        return out
    }

    /// Map signal number to its POSIX name. Returns `"UNKNOWN"` for unhandled signals.
    /// Allocation-free: returns pointer to static C string. Safe to call from a signal handler.
    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGILL:  return "SIGILL"
        case SIGBUS:  return "SIGBUS"
        case SIGFPE:  return "SIGFPE"
        case SIGPIPE: return "SIGPIPE"
        default:      return "UNKNOWN"
        }
    }

    // MARK: - ASCII helpers (no String interpolation; caller provides preformatted parts)

    @inline(__always)
    private static func appendASCII(_ out: inout [UInt8], _ s: String) {
        for b in s.utf8 { out.append(b) }
    }

    @inline(__always)
    private static func appendUInt(_ out: inout [UInt8], _ n: UInt64) {
        if n == 0 { out.append(UInt8(ascii: "0")); return }
        var buf: [UInt8] = []
        var x = n
        while x > 0 {
            buf.append(UInt8(ascii: "0") &+ UInt8(x % 10))
            x /= 10
        }
        for i in (0..<buf.count).reversed() { out.append(buf[i]) }
    }

    @inline(__always)
    private static func appendInt(_ out: inout [UInt8], _ n: Int64) {
        if n < 0 {
            out.append(UInt8(ascii: "-"))
            appendUInt(&out, UInt64(-(n + 1)) &+ 1)
        } else {
            appendUInt(&out, UInt64(n))
        }
    }
}
