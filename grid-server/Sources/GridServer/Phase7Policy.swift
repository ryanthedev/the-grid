// Phase7Policy.swift
//
// Pure decision predicates for Phase 7 (silent errors, crash safety & infra).
// Each helper is OS-boundary-free so the logic is unit-testable without AX,
// SkyLight, sockets, or a live process. The call sites that touch the OS are
// thin wrappers around these.

import Foundation
import ApplicationServices

// MARK: - #34  App AX element with bounded messaging timeout

/// Create an AX application element with a messaging timeout already applied,
/// so blocking AX IPC to a beachballing app degrades to a fast
/// kAXErrorCannotComplete instead of freezing the actor for the ~6s default.
/// Use this everywhere `AXUIElementCreateApplication` was called directly (#34).
func makeAppElement(pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, AXMessagingTimeoutPolicy.timeoutSeconds)
    return element
}

// MARK: - #1 / #46  Socket write safety

/// Result of a full-write attempt to a client socket fd.
enum WriteResult: Equatable {
    /// All bytes written.
    case ok
    /// Peer hung up (EPIPE / ECONNRESET / send returned 0). The server must
    /// NOT die — the caller logs `sock.err` and drops the client.
    case disconnected
    /// Other terminal error; carries errno for logging.
    case failed(Int32)
}

/// Full-write loop primitive. `send` is injected so the loop is testable
/// against partial writes, EINTR, EAGAIN, and EPIPE without a real socket.
/// On macOS the accepted socket carries SO_NOSIGPIPE, so a dead peer returns
/// EPIPE here instead of raising a fatal signal (#1).
enum FullWrite {
    /// Write every byte in `bytes`, looping on partial writes and retryable
    /// errors. `send(buf, len)` returns bytes sent (>=0) or -1 with `errnoValue`
    /// set; the closure returns (result, errno).
    static func writeAll(
        _ bytes: [UInt8],
        send: (UnsafeRawPointer, Int) -> (Int, Int32)
    ) -> WriteResult {
        var offset = 0
        let total = bytes.count
        if total == 0 { return .ok }
        return bytes.withUnsafeBytes { raw -> WriteResult in
            guard let base = raw.baseAddress else { return .ok }
            while offset < total {
                let (sent, err) = send(base.advanced(by: offset), total - offset)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent == 0 {
                    // send() returning 0 on a stream socket means the peer closed.
                    return .disconnected
                }
                // sent < 0 — inspect errno.
                switch err {
                case EINTR, EAGAIN:
                    // Retryable: try again.
                    continue
                case EPIPE, ECONNRESET, ENOTCONN, EBADF:
                    return .disconnected
                default:
                    return .failed(err)
                }
            }
            return .ok
        }
    }
}

// MARK: - #34  AX messaging timeout

/// Timeout applied to per-app AX IPC so a beachballing app cannot freeze the
/// actor for the ~6s system default. 0.5s is long enough for healthy apps,
/// short enough that a hung app degrades to a fast kAXErrorCannotComplete.
enum AXMessagingTimeoutPolicy {
    static let timeoutSeconds: Float = 0.5

    static func isSane(_ t: Float) -> Bool {
        return t > 0 && t <= 2.0
    }
}

// MARK: - #33  Observer slot reservation (TOCTOU guard)

/// Decision for whether a new AX observer may be created for a pid. The slot is
/// reserved synchronously on the actor before the MainActor install; a second
/// call must be rejected if an observer is already installed OR a creation is
/// already in flight (the window the original nil-only guard missed).
enum ObserverSlotPolicy {
    static func canCreate(installed: Bool, inFlight: Bool) -> Bool {
        return !installed && !inFlight
    }
}

// MARK: - #36  MSS re-probe

/// When MSS real operations fail repeatedly, the cached-true verdict is stale
/// (e.g. Dock restarted, killing the Dock-side socket). Re-probe after a small
/// run of consecutive failures rather than failing every move until restart.
enum MSSReprobePolicy {
    static let failureThreshold = 3

    static func shouldReprobe(consecutiveFailures: Int) -> Bool {
        return consecutiveFailures >= failureThreshold
    }
}

// MARK: - #37  BFD config watcher re-arm

/// A DispatchSource on a renamed/deleted inode goes deaf. When the event
/// carries .rename or .delete the watcher must cancel and re-open the path.
enum ConfigWatcherPolicy {
    static func shouldRearm(eventFlags: DispatchSource.FileSystemEvent) -> Bool {
        return eventFlags.contains(.rename) || eventFlags.contains(.delete)
    }
}

// MARK: - #39  Terminal off-screen sentinel

/// hide() parks the window at (-10000,-10000). A frame at/near that sentinel
/// must never be persisted, or every future show() restores off-screen.
enum TerminalFramePolicy {
    static let sentinel = CGPoint(x: -10000, y: -10000)
    // Anything this far off the top-left is treated as the parked sentinel.
    static let threshold: CGFloat = 5000

    static func isOffScreenSentinel(_ frame: CGRect) -> Bool {
        return frame.origin.x <= -threshold || frame.origin.y <= -threshold
    }
}

// MARK: - #47  BFD app match by bundle id

/// BFD blacklist/per-app keys are documented as bundle identifiers. Match the
/// frontmost app's bundleIdentifier first; fall back to localizedName so
/// existing display-name configs keep working (back-compat, not blind).
enum AppMatchPolicy {
    /// Does `configKey` identify the running app described by (bundleID, name)?
    static func matches(configKey: String, bundleID: String?, name: String?) -> Bool {
        if let b = bundleID, configKey == b { return true }
        if let n = name, configKey == n { return true }
        return false
    }

    /// Is any blacklist key a match for this app?
    static func isBlacklisted(_ keys: Set<String>, bundleID: String?, name: String?) -> Bool {
        if let b = bundleID, keys.contains(b) { return true }
        if let n = name, keys.contains(n) { return true }
        return false
    }

    /// Resolve the config dictionary key (bundle id preferred) for per-app
    /// overrides, returning nil if neither id nor name has an entry.
    static func resolveKey(_ keys: Set<String>, bundleID: String?, name: String?) -> String? {
        if let b = bundleID, keys.contains(b) { return b }
        if let n = name, keys.contains(n) { return n }
        return nil
    }
}

// MARK: - #22  @notify action dispatch

/// Distinct distributed-notification names per @notify action. Collapsing all
/// actions to a single toggle (the bug) is replaced with one name per action;
/// payload-bearing actions (push/dismiss/assign) forward userInfo.
enum NotifyActionPolicy {
    static let prefix = "com.thegrid.notify"

    /// Distributed-notification name for an action, or nil for actions with no
    /// notification (none currently — list/count are queries but still routed).
    static func notificationName(forAction action: String) -> String {
        switch action {
        case "show": return "\(prefix).show"
        case "hide": return "\(prefix).hide"
        case "toggle", "": return "\(prefix).toggle"
        case "push": return "\(prefix).push"
        case "dismiss": return "\(prefix).dismiss"
        case "clear": return "\(prefix).clear"
        case "list": return "\(prefix).list"
        case "count": return "\(prefix).count"
        case "assign": return "\(prefix).assign"
        case "unassign": return "\(prefix).unassign"
        default: return "\(prefix).toggle"
        }
    }

    /// Whether an action carries a payload that must be forwarded as userInfo.
    static func carriesPayload(_ action: String) -> Bool {
        switch action {
        case "push", "dismiss", "assign": return true
        default: return false
        }
    }

    /// Notify command params buildCommand must forward (was dropping these).
    static let forwardableParams: [String] = [
        "title", "body", "priority", "source", "id", "action", "purge", "cell", "all",
    ]

    /// String-valued notify params encoded as `--key "value"` flags.
    static let valueFlags: [String] = ["title", "body", "priority", "source", "id"]

    /// Build the trailing `--flag "value"` tokens for a @notify command from a
    /// param lookup. Pure so the forwarding (previously dropped — the #22 bug)
    /// is unit-testable. `lookup` returns a string value for a param, or nil.
    static func payloadFlags(lookup: (String) -> String?, purge: Bool) -> [String] {
        var parts: [String] = []
        for flag in valueFlags {
            if let val = lookup(flag) {
                parts.append("--\(flag)")
                parts.append("\"\(val)\"")
            }
        }
        if purge {
            parts.append("--purge")
        }
        return parts
    }
}
