import Darwin
import Foundation

/// Crash-exit instrumentation for grid-server. Installs:
///
///   - Async-signal-safe handlers for SIGSEGV/SIGABRT/SIGILL/SIGBUS/SIGFPE/SIGPIPE
///     that write one preformatted `srv.fatal` line to a pre-opened log fd and
///     call `_exit(128+sig)`. These handlers never touch the Swift runtime,
///     allocator, Foundation, DispatchQueue, or String — they use only
///     `Darwin.write`, `getpid`, `clock_gettime`, `time`, integer math, and a
///     preallocated C buffer.
///
///   - A Swift-runtime-safe `NSSetUncaughtExceptionHandler` that logs
///     `srv.fatal.exception {name, reason}` before ObjC terminates the process.
///     This path CAN use jlog/allocator because an uncaught exception leaves the
///     runtime intact, unlike a hardware fault.
///
///   - An `atexit(3)` hook that logs `srv.atexit` on normal termination paths
///     (`Darwin.exit`, `ExitCode.failure`, `NSApp.stop`). Does not fire on
///     `_exit` (the fatal signal path) or `SIGKILL` / launchd kill.
///
/// The existing SIGINT/SIGTERM DispatchSource handlers in main.swift are NOT
/// touched — they keep emitting `srv.shutdown.done` then `Darwin.exit(0)`,
/// which runs atexit → `srv.atexit {code:0}`.
enum CrashReporter {

    // MARK: - State (async-signal-safe accessible)

    /// File descriptor for appending srv.fatal lines. Opened once at install
    /// with `O_WRONLY | O_APPEND | O_CREAT`. Set to -1 if install failed, which
    /// makes the handlers no-op rather than crash a crashing process.
    nonisolated(unsafe) private static var logFd: Int32 = -1

    /// Monotonic seconds at install time, for uptime computation inside handlers.
    nonisolated(unsafe) private static var startMonotonicSec: UInt64 = 0

    /// Static write buffer reused by all signal handlers. 256 bytes is more than
    /// enough for the longest `srv.fatal` line we emit. Allocated once at
    /// install; never freed.
    nonisolated(unsafe) private static var writeBuffer: UnsafeMutablePointer<UInt8>? = nil
    private static let writeBufferCapacity: Int = 256

    /// Set via `sig_atomic_t`-like semantics to short-circuit a nested fault
    /// while we're in the middle of writing a fatal line.
    nonisolated(unsafe) private static var inFatal: Int32 = 0

    // MARK: - Public API

    /// Wire up all crash-exit instrumentation. Call this AFTER classifying the
    /// previous exit but BEFORE the first `srv.start` of this run, so that the
    /// earliest possible crash is caught.
    static func install() {
        // Capture start time for uptime calculation in handlers.
        startMonotonicSec = monotonicSeconds()

        // Open dedicated append fd to the log file. Reuses JSONLogWriter's path.
        let path = JSONLogger.shared.getLogPath()
        let fd = path.withCString { cpath -> Int32 in
            // Mode 0644 — owner rw, others r.
            return open(cpath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        if fd < 0 {
            jlog("warn.crash.fd", msg: "failed to open log fd for crash reporter",
                 data: ["errno": Int(errno), "path": path])
            return
        }
        logFd = fd

        // Allocate the preformatting buffer once.
        writeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: writeBufferCapacity)

        // Install the six fatal signal handlers.
        installSignal(SIGSEGV)
        installSignal(SIGABRT)
        installSignal(SIGILL)
        installSignal(SIGBUS)
        installSignal(SIGFPE)
        installSignal(SIGPIPE)

        // Install ObjC uncaught exception handler (Swift-runtime-safe path).
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? ""
            jlog("srv.fatal.exception", data: [
                "name": name,
                "reason": reason,
            ])
            // Give the logger a beat to flush before ObjC terminates us.
            // JSONLogWriter batches with a 0.1s timer; 200ms is safe.
            usleep(200_000)
        }

        // atexit: normal termination path (runs after Darwin.exit, not _exit).
        atexit {
            jlog("srv.atexit")
            JSONLogWriter.shared.flushSync()
        }
    }

    // MARK: - Signal handler install

    private static func installSignal(_ sig: Int32) {
        var action = sigaction()
        // Note: `__sigaction_u.__sa_handler` is the C-function handler field.
        action.__sigaction_u = __sigaction_u(__sa_handler: crashSignalHandler)
        // SA_RESETHAND: restore default handler after first fire, so a nested
        // fault during our write produces a core dump via default action
        // rather than looping in our handler.
        action.sa_flags = SA_RESETHAND
        sigemptyset(&action.sa_mask)
        sigaction(sig, &action, nil)
    }

    // MARK: - The async-signal-safe handler

    /// Global C-function signal handler. MUST remain async-signal-safe:
    ///   - no Swift String, Dictionary, Array allocation
    ///   - no Foundation, Logger, JSONLogger, NSException
    ///   - no DispatchQueue, locks, TaskLocal
    ///   - only: Darwin.write, getpid, clock_gettime, time, _exit, arithmetic,
    ///     raw pointer ops, comparisons
    private static let crashSignalHandler: @convention(c) (Int32) -> Void = { sig in
        // Guard against re-entry (nested fault while writing).
        if CrashReporter.inFatal != 0 {
            Darwin._exit(128 &+ sig)
        }
        CrashReporter.inFatal = 1

        let fd = CrashReporter.logFd
        let buf = CrashReporter.writeBuffer
        if fd < 0 || buf == nil {
            Darwin._exit(128 &+ sig)
        }

        // Build the line directly into the preallocated buffer. We mirror
        // FatalFormatter.formatFatal's layout exactly so tests cover the format.
        var n: Int = 0
        let cap = CrashReporter.writeBufferCapacity

        writeASCII(buf!, cap, &n, "{\"ev\":\"srv.fatal\",\"data\":{\"pid\":")
        writeUInt(buf!, cap, &n, UInt64(getpid()))
        writeASCII(buf!, cap, &n, ",\"sig\":\"")
        // Inline signal-name lookup (no String return from a helper — stay simple).
        switch sig {
        case SIGSEGV: writeASCII(buf!, cap, &n, "SIGSEGV")
        case SIGABRT: writeASCII(buf!, cap, &n, "SIGABRT")
        case SIGILL:  writeASCII(buf!, cap, &n, "SIGILL")
        case SIGBUS:  writeASCII(buf!, cap, &n, "SIGBUS")
        case SIGFPE:  writeASCII(buf!, cap, &n, "SIGFPE")
        case SIGPIPE: writeASCII(buf!, cap, &n, "SIGPIPE")
        default:      writeASCII(buf!, cap, &n, "UNKNOWN")
        }
        writeASCII(buf!, cap, &n, "\",\"uptime\":")
        let nowMono = CrashReporter.monotonicSeconds()
        let uptime = nowMono >= CrashReporter.startMonotonicSec
            ? nowMono &- CrashReporter.startMonotonicSec
            : 0
        writeUInt(buf!, cap, &n, uptime)
        writeASCII(buf!, cap, &n, "},\"ts\":")
        // time(nil) is POSIX async-signal-safe.
        writeUInt(buf!, cap, &n, UInt64(time(nil)))
        writeASCII(buf!, cap, &n, "}\n")

        // Single write call. Partial writes on a local file with this small a
        // payload are effectively impossible; we don't loop.
        _ = Darwin.write(fd, buf!, n)

        Darwin._exit(128 &+ sig)
    }

    // MARK: - Async-signal-safe helpers

    /// Monotonic seconds since an arbitrary epoch. `clock_gettime` with
    /// `CLOCK_MONOTONIC` is async-signal-safe on macOS.
    @inline(__always)
    private static func monotonicSeconds() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec)
    }

    /// Append a Swift string literal's UTF-8 bytes into the buffer. Literal
    /// strings store their bytes inline; iterating `.utf8` is allocation-free.
    @inline(__always)
    private static func writeASCII(_ buf: UnsafeMutablePointer<UInt8>, _ cap: Int, _ n: inout Int, _ s: StaticString) {
        s.withUTF8Buffer { bytes in
            for b in bytes {
                if n >= cap { return }
                buf[n] = b
                n &+= 1
            }
        }
    }

    /// Append a base-10 unsigned integer's ASCII into the buffer.
    @inline(__always)
    private static func writeUInt(_ buf: UnsafeMutablePointer<UInt8>, _ cap: Int, _ n: inout Int, _ value: UInt64) {
        if value == 0 {
            if n < cap { buf[n] = UInt8(ascii: "0"); n &+= 1 }
            return
        }
        // Max 20 decimal digits for UInt64. Write into a local stack array.
        var tmp: (UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0)
        var count: Int = 0
        var v = value
        withUnsafeMutableBytes(of: &tmp) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while v > 0 {
                p[count] = UInt8(ascii: "0") &+ UInt8(v % 10)
                v /= 10
                count &+= 1
            }
            // Reverse into output buffer.
            var i = count
            while i > 0 {
                i &-= 1
                if n >= cap { return }
                buf[n] = p[i]
                n &+= 1
            }
        }
    }
}
