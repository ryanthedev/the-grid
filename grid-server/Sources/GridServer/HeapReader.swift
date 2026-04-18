//
// HeapReader.swift
// GridServer
//
// Reads the current process's resident memory via Mach task_info.
// Used by the srv.alive heartbeat to rule in/out memory growth as a crash
// correlate. Returns 0 on failure — callers treat 0 as "unavailable".
//

import Foundation
import Darwin

enum HeapReader {

    // Return the current process's resident size in megabytes.
    //
    // Uses MACH_TASK_BASIC_INFO.resident_size — the portion of the task's
    // virtual memory backed by physical RAM. Good enough for trend detection
    // (the DW only requires non-zero on a live process).
    static func readHeapMb() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return UInt64(info.resident_size) / (1024 * 1024)
    }
}

// Pure predicate for tick-based emission. Validator timer runs every 30s,
// so emitting on even ticks gives a 60s heartbeat cadence.
enum HeartbeatScheduler {
    static func shouldEmit(tickCount: Int) -> Bool {
        return tickCount > 0 && tickCount % 2 == 0
    }
}
