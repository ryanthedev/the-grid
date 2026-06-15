//
// ProcessArgsReader.swift
// GridServer
//
// Thin, well-guarded boundary that reads a process's launch arguments via
// sysctl KERN_PROCARGS2 — no subprocess (matches ChromeEnricher's file-I/O-only
// convention). All buffer parsing is bounds-checked against the length sysctl
// reports; any failure returns nil (logged once) and never crashes.
//
// Process args are immutable for a process lifetime, so results are cached
// per PID. The cache stores the resolved Optional so a resolved-nil is not
// re-read on every picker open.
//

import Foundation

final class ProcessArgsReader {
    // pid -> resolved user-data-dir (or nil). Caching the Optional means a PID
    // that has no --user-data-dir (or failed to read) is not re-read.
    private var cache: [pid_t: String?] = [:]

    // Log the KERN_PROCARGS2 failure event at most once per reader lifetime so
    // a transient failure does not spam the log on every picker open.
    private var loggedFailure = false

    // Resolve the --user-data-dir for a PID. Returns nil when the flag is
    // absent, the process is gone, or the buffer is unreadable.
    func userDataDir(forPID pid: pid_t) -> String? {
        if let cached = cache[pid] {
            return cached
        }
        let resolved = readUserDataDir(forPID: pid)
        cache[pid] = resolved
        return resolved
    }

    // For tests: clear the per-PID cache.
    func _test_clearCache() {
        cache.removeAll()
    }

    private func readUserDataDir(forPID pid: pid_t) -> String? {
        guard let argv = readArgv(forPID: pid) else {
            return nil
        }
        return ChromeInstancePolicy.extractUserDataDir(argv: argv)
    }

    // Read the full argv for a PID via KERN_PROCARGS2. Returns nil on any
    // syscall error, a truncated buffer, or undecodable bytes.
    private func readArgv(forPID pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        // First call sizes the buffer (NULL data pointer).
        var bufferSize = 0
        let sizeResult = sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0)
        guard sizeResult == 0, bufferSize > 0 else {
            logFailureOnce(pid: pid, reason: "size")
            return nil
        }

        var buffer = [CChar](repeating: 0, count: bufferSize)
        var fetchedSize = bufferSize
        let fetchResult = sysctl(&mib, UInt32(mib.count), &buffer, &fetchedSize, nil, 0)
        guard fetchResult == 0, fetchedSize > 0 else {
            logFailureOnce(pid: pid, reason: "fetch")
            return nil
        }

        return parseArgv(buffer: buffer, length: fetchedSize, pid: pid)
    }

    // Parse the KERN_PROCARGS2 buffer:
    //   [argc: Int32][exec_path\0][padding \0…][argv0\0 … argv{argc-1}\0][env…]
    // Every read is bounded to `length` (the byte count sysctl returned). Any
    // out-of-bounds or undecodable condition returns nil.
    private func parseArgv(buffer: [CChar], length: Int, pid: pid_t) -> [String]? {
        let argcSize = MemoryLayout<Int32>.size
        guard length >= argcSize else {
            logFailureOnce(pid: pid, reason: "truncated.argc")
            return nil
        }

        // Read argc from the first 4 bytes.
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(argcSize))
            }
        }
        guard argc > 0 else {
            logFailureOnce(pid: pid, reason: "argc.nonpositive")
            return nil
        }

        // Treat the buffer as unsigned bytes for scanning.
        let bytes: [UInt8] = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        var offset = argcSize

        // Skip the exec path string (NUL-terminated).
        while offset < bytes.count && bytes[offset] != 0 {
            offset += 1
        }
        // Skip the NUL terminators / padding after the exec path.
        while offset < bytes.count && bytes[offset] == 0 {
            offset += 1
        }
        guard offset < bytes.count else {
            logFailureOnce(pid: pid, reason: "truncated.path")
            return nil
        }

        // Read exactly argc NUL-terminated args, bounded to the buffer.
        var args: [String] = []
        args.reserveCapacity(Int(argc))
        var readArgs = 0
        while readArgs < Int(argc) && offset < bytes.count {
            let start = offset
            while offset < bytes.count && bytes[offset] != 0 {
                offset += 1
            }
            guard offset < bytes.count else {
                logFailureOnce(pid: pid, reason: "truncated.arg")
                return nil
            }
            let slice = bytes[start..<offset]
            guard let arg = String(bytes: slice, encoding: .utf8) else {
                logFailureOnce(pid: pid, reason: "undecodable")
                return nil
            }
            args.append(arg)
            // Advance past the NUL terminator.
            offset += 1
            readArgs += 1
        }

        guard readArgs == Int(argc) else {
            logFailureOnce(pid: pid, reason: "truncated.args")
            return nil
        }
        return args
    }

    private func logFailureOnce(pid: pid_t, reason: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        jlog("err.chrome.procargs", data: ["pid": pid, "reason": reason])
    }
}
