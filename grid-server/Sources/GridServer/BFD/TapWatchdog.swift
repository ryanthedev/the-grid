import Foundation
import CoreGraphics
import ApplicationServices

/// What the watchdog should do after one interval.
enum TapWatchdogVerdict: Equatable {
    /// The tap saw keys, or nothing can be concluded this interval.
    case ok
    /// The system saw keys the tap did not; not yet enough to act.
    case suspect
    /// Deaf for long enough: tear the tap down and create a new one.
    case recreateTap
    /// Still deaf after a recreate: exit so launchd starts a fresh process.
    case restartServer
    /// Still deaf, but a deafness restart happened recently; recreate again
    /// rather than risk a restart loop.
    case stillDeaf
}

/// Pure decision logic for the BFD tap watchdog.
///
/// On ska the tap stayed enabled and valid while hotkeys went dead (cmd-h fell
/// through and hid apps), and only restarting the server brought them back.
/// The watchdog compares the system's own keyDown counter with the keyDowns the
/// tap actually received: keys the system saw and the tap did not mean the tap
/// is deaf, whatever tapIsEnabled says.
struct TapWatchdogPolicy {
    /// Fewer keys than this in an interval is not evidence either way.
    static let minSystemKeys = 3
    /// Consecutive deaf intervals before acting, so one sampling race can't.
    static let intervalsToAct = 2

    private(set) var deafIntervals = 0
    private(set) var recreated = false

    /// - Parameters:
    ///   - inconclusive: the tap was suspended (picker), Secure Input was on,
    ///     or agent input was posted; the counters can't be compared.
    mutating func evaluate(systemKeys: Int, tapKeys: Int, inconclusive: Bool,
                           restartAllowed: Bool) -> TapWatchdogVerdict {
        if inconclusive {
            deafIntervals = 0
            return .ok
        }
        if tapKeys > 0 {
            deafIntervals = 0
            recreated = false
            return .ok
        }
        guard systemKeys >= Self.minSystemKeys else { return .ok }

        deafIntervals += 1
        guard deafIntervals >= Self.intervalsToAct else { return .suspect }
        deafIntervals = 0
        if !recreated {
            recreated = true
            return .recreateTap
        }
        return restartAllowed ? .restartServer : .stillDeaf
    }
}

/// Live snapshot taken when the tap is found deaf, to tell apart a revoked
/// permission, a tap WindowServer no longer lists, and another process's tap.
enum TapDiagnostics {
    static func snapshot() -> [String: Any] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)

        let me = getpid()
        let keyMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let keyTaps = taps.prefix(Int(count)).filter { $0.eventsOfInterest & keyMask != 0 }
        let mine = keyTaps.filter { $0.tappingProcess == me }
        let others = keyTaps.filter { $0.tappingProcess != me }.map { tap -> String in
            let name = SecureInputMonitor.appName(tap.tappingProcess)
            return "\(name)(\(tap.tappingProcess))\(tap.enabled ? "" : ":off")"
        }

        return [
            "axTrusted": AXIsProcessTrusted(),
            "listenAccess": CGPreflightListenEventAccess(),
            "myTaps": mine.count,
            "myTapsEnabled": mine.filter { $0.enabled }.count,
            "myMaxLatencyUs": Int(mine.map { $0.maxUsecLatency }.max() ?? 0),
            "otherKeyTaps": Array(Set(others)).sorted()
        ]
    }
}

/// Where the last deafness restart is recorded, so a false positive can't turn
/// into a restart loop. Lives next to the server log (redirected under tests).
enum TapRestartMarker {
    static let cooldown: TimeInterval = 600

    private static var path: String {
        (JSONLogger.shared.getLogPath() as NSString)
            .deletingLastPathComponent + "/bfd-deaf-restart"
    }

    static func restartAllowed(now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let written = attrs[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(written) >= cooldown
    }

    static func record() {
        FileManager.default.createFile(atPath: path, contents: Data())
    }
}
