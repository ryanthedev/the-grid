//
// SerializationPrimitives.swift
// GridServer
//
// Phase 1 reusable primitives for the serialization foundation. Each type is a
// pure value type with no AX/SkyLight imports so it can be unit-tested off the
// boundary and embedded into GridReconciler / the command path.
//
//   RefcountedFence       — DW-1.3: refcounted per-window fence (acquire/release).
//   GenerationCounter     — DW-1.7: monotonic action generation for stale-snapshot detection.
//   SuppressedEventQueue  — DW-1.6: ordered buffer of events dropped during suppression, replayed at depth 0.
//   ActionTokenRegistry   — DW-1.4: consume-once action tokens with unique identity.
//   NudgeStepQueue        — DW-1.5: same-direction nudge step coalescing that carries the frame forward.
//

import Foundation
import CoreGraphics

// MARK: - RefcountedFence (DW-1.3, #14)

// Per-window fence with a refcount. Overlapping acquisitions of the same window
// each increment the count; the entry is removed only when the count returns to
// zero. A shared expiry guards against a leaked acquire deadlocking the window.
//
// Replaces the previous overwrite-expiry map where releaseFence unconditionally
// deleted the entry — stripping an in-flight overlapping move's fence.
struct RefcountedFence {

    private struct Entry {
        var count: Int
        var expiresAt: CFAbsoluteTime
    }

    private var entries: [UInt32: Entry] = [:]
    private let timeout: CFAbsoluteTime

    init(timeout: CFAbsoluteTime) {
        self.timeout = timeout
    }

    // Acquire a fence for windowID. Increments the refcount and refreshes expiry.
    // Returns the new refcount.
    @discardableResult
    mutating func acquire(_ windowID: UInt32, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Int {
        let expiresAt = now + timeout
        if var entry = entries[windowID] {
            entry.count += 1
            entry.expiresAt = expiresAt
            entries[windowID] = entry
            return entry.count
        }
        entries[windowID] = Entry(count: 1, expiresAt: expiresAt)
        return 1
    }

    // Release one acquisition of windowID. Removes the entry only when the
    // refcount reaches zero. Releasing an unheld window is a no-op (returns 0).
    // Returns the remaining refcount (0 when removed or never held).
    @discardableResult
    mutating func release(_ windowID: UInt32) -> Int {
        guard var entry = entries[windowID] else {
            return 0
        }
        entry.count -= 1
        if entry.count <= 0 {
            entries.removeValue(forKey: windowID)
            return 0
        }
        entries[windowID] = entry
        return entry.count
    }

    // True if windowID is fenced and not expired. Lazily clears an expired entry.
    mutating func isFenced(_ windowID: UInt32, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard let entry = entries[windowID] else { return false }
        if now > entry.expiresAt {
            entries.removeValue(forKey: windowID)
            return false
        }
        return true
    }

    // Current refcount for windowID (0 if not held). Does not mutate.
    func depth(_ windowID: UInt32) -> Int {
        entries[windowID]?.count ?? 0
    }

    // All currently-fenced window IDs that have not expired as of `now`.
    func activeWindows(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Set<UInt32> {
        var result: Set<UInt32> = []
        for (wid, entry) in entries where now <= entry.expiresAt {
            result.insert(wid)
        }
        return result
    }
}

// MARK: - GenerationCounter (DW-1.7, primitive for P2/P3)

// Monotonic counter bumped once per action. A handler/sweep snapshots `current`
// before an `await` and re-reads it afterward; a changed value means an action
// ran in between and the pre-await snapshot is stale.
struct GenerationCounter {

    private(set) var current: UInt64 = 0

    // Increment and return the new generation.
    @discardableResult
    mutating func bump() -> UInt64 {
        current &+= 1
        return current
    }
}

// MARK: - SuppressedEventQueue (DW-1.6, #12)

// The subset of reconciler events that must not be lost when dropped during
// suppression. Equatable so tests can assert exact replay order.
enum SuppressibleEvent: Equatable {
    case windowCreated(wid: UInt32)
    case windowDestroyed(wid: UInt32)
}

// Ordered buffer of events that arrived while suppressionDepth > 0. Drained FIFO
// when depth returns to 0 so each create/destroy is replayed in arrival order
// instead of being silently dropped.
struct SuppressedEventQueue {

    struct Entry: Equatable {
        let event: SuppressibleEvent
        let generation: UInt64
    }

    private var buffer: [Entry] = []

    var count: Int { buffer.count }
    var isEmpty: Bool { buffer.isEmpty }

    // Append an event with the generation it was observed under.
    mutating func enqueue(_ event: SuppressibleEvent, generation: UInt64) {
        buffer.append(Entry(event: event, generation: generation))
    }

    // Remove and return all queued entries in arrival order. Leaves the queue empty,
    // so a replayed event is consumed exactly once.
    mutating func drain() -> [Entry] {
        let drained = buffer
        buffer.removeAll(keepingCapacity: false)
        return drained
    }
}

// MARK: - ActionTokenRegistry (DW-1.4, #4)

// Consume-once action tokens. Each begin() mints a token with a unique id;
// consume() succeeds exactly once per token. A second consume of the same token
// (e.g. two racing @nudge exit submits) is rejected without touching another
// session's suppression.
struct ConsumableActionToken: Equatable {
    let id: UInt64
    let label: String
    let startTime: CFAbsoluteTime
}

struct ActionTokenRegistry {

    private var nextID: UInt64 = 0
    private var active: Set<UInt64> = []

    // Begin a session and return its unique token.
    mutating func begin(label: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> ConsumableActionToken {
        nextID &+= 1
        let token = ConsumableActionToken(id: nextID, label: label, startTime: now)
        active.insert(token.id)
        return token
    }

    // True while the token has not yet been consumed.
    func isActive(_ token: ConsumableActionToken) -> Bool {
        active.contains(token.id)
    }

    // Consume the token. Returns true the first time, false on any later attempt.
    mutating func consume(_ token: ConsumableActionToken) -> Bool {
        active.remove(token.id) != nil
    }

    // Consume by raw id (for callers that hold only the id). Same once-only semantics.
    mutating func consume(id: UInt64) -> Bool {
        active.remove(id) != nil
    }
}

// MARK: - NudgeStepQueue (DW-1.5, #50)

// Coalesces held-key nudge repeats by carrying the frame forward between steps
// instead of re-reading a stale cached frame. Each advance applies exactly one
// step from the caller-supplied current value, so N submits yield N ordered
// steps (none lost, none back-stepped from a stale read).
struct NudgeStepQueue {

    private let step: CGFloat

    init(step: CGFloat) {
        self.step = step
    }

    // Apply one step in `direction` to `current`, returning the new value.
    // Left/right and up/down share the same axis math; the caller picks the axis.
    func advance(current: CGFloat, direction: GridDirection) -> CGFloat {
        switch direction {
        case .left, .up:
            return current - step
        case .right, .down:
            return current + step
        }
    }
}
