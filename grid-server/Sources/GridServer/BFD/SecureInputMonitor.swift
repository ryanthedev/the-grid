import Foundation
import AppKit
import Carbon.HIToolbox

/// What changed in Secure Event Input between two polls.
enum SecureInputTransition: Equatable {
    case began(pid: Int32?)
    case ended(seconds: Int)
    case stuck(pid: Int32?, seconds: Int)
}

/// Pure state machine over polled Secure Event Input readings.
///
/// Secure Event Input (password fields, a terminal's sudo prompt, "Secure
/// Keyboard Entry") hides every keystroke from event taps. The BFD tap stays
/// enabled and valid, so the health check stays green, while hotkeys silently
/// stop and keys such as cmd-h fall through to the app. Only polling sees it.
struct SecureInputPolicy {
    /// A password prompt holds Secure Input for a few seconds; past this it is
    /// what the user experiences as "the grid stopped responding".
    static let stuckAfter: TimeInterval = 20

    private(set) var since: Date?
    private(set) var pid: Int32?
    private var warned = false

    mutating func update(enabled: Bool, pid newPid: Int32?, now: Date) -> [SecureInputTransition] {
        guard enabled else {
            guard let start = since else { return [] }
            since = nil
            pid = nil
            warned = false
            return [.ended(seconds: Int(now.timeIntervalSince(start)))]
        }

        var out: [SecureInputTransition] = []
        // The session's reported pid follows the frontmost app while Secure
        // Input is on (measured), so it is a hint, not an episode boundary.
        if since == nil {
            since = now
            out.append(.began(pid: newPid))
        }
        pid = newPid ?? pid
        if !warned, let start = since, now.timeIntervalSince(start) >= Self.stuckAfter {
            warned = true
            out.append(.stuck(pid: pid, seconds: Int(now.timeIntervalSince(start))))
        }
        return out
    }
}

/// Polls Secure Event Input every couple of seconds and logs it, so the tap
/// watchdog and the log can tell a blinded tap from a broken one.
final class SecureInputMonitor {
    private var policy = SecureInputPolicy()
    private var timer: Timer?

    /// Current reading, for the BFD health log.
    static var isEnabled: Bool { IsSecureEventInputEnabled() }

    /// Must be called on the main thread (the timer joins the main run loop).
    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.fire()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let enabled = IsSecureEventInputEnabled()
        let pid = enabled ? Self.holderPID() : nil
        for transition in policy.update(enabled: enabled, pid: pid, now: Date()) {
            report(transition)
        }
    }

    private func report(_ transition: SecureInputTransition) {
        switch transition {
        case .began(let pid):
            let app = Self.appName(pid)
            Task { JSONLogger.shared.log("bfd.secure_input.on", data: ["frontPid": Int(pid ?? -1), "frontApp": app]) }
        case .ended(let seconds):
            Task { JSONLogger.shared.log("bfd.secure_input.off", data: ["secs": seconds]) }
        case .stuck(let pid, let seconds):
            let app = Self.appName(pid)
            Task {
                JSONLogger.shared.log("warn.bfd.secure_input", msg: "hotkeys blocked by Secure Input",
                                      data: ["frontPid": Int(pid ?? -1), "frontApp": app, "secs": seconds])
            }
        }
    }

    /// The session dictionary's Secure Input pid. Measured on macOS 26: it
    /// tracks the frontmost app while Secure Input is on, not the holder.
    static func holderPID() -> Int32? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }

    static func appName(_ pid: Int32?) -> String {
        guard let pid = pid, let app = NSRunningApplication(processIdentifier: pid) else { return "unknown" }
        return app.localizedName ?? app.bundleIdentifier ?? "unknown"
    }
}
