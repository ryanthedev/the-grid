import Foundation
import CoreGraphics
import AppKit

/// Handles keyboard events via CGEventTap
class BFDKeyHandler {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled: Bool = false

    // Hotkey lookup tables
    private var globalHotkeys: [BFDHotkeyKey: (spec: String, def: BFDHotkeyDef)] = [:]
    private var appHotkeys: [String: [BFDHotkeyKey: BFDAppHotkey]] = [:]
    private var blacklist: Set<String> = []

    // Rate limiting
    private var lastExecutionTime: [BFDHotkeyKey: Date] = [:]
    private let lastExecutionTimeLock = NSLock()
    private var config: BFDConfig?

    // Health check timer
    private var healthCheckTimer: Timer?

    // Callbacks
    var onHotkeyTriggered: ((String, BFDHotkeyDef) -> Void)?

    init() {}

    deinit {
        stop()
    }

    /// Update configuration (rebuilds lookup tables)
    func updateConfig(_ config: BFDConfig) {
        self.config = config
        self.blacklist = Set(config.blacklist)

        // Rebuild global hotkeys
        globalHotkeys.removeAll()
        for (spec, def) in config.hotkeys {
            do {
                let key = try parseBFDHotkey(spec)
                globalHotkeys[key] = (spec, def)
            } catch {
                BFDLogger.logError("Failed to parse hotkey '\(spec)': \(error)")
            }
        }

        // Rebuild app hotkeys
        appHotkeys.removeAll()
        for (app, hotkeys) in config.apps {
            var appMap: [BFDHotkeyKey: BFDAppHotkey] = [:]
            for (spec, appHk) in hotkeys {
                do {
                    let key = try parseBFDHotkey(spec)
                    appMap[key] = appHk
                } catch {
                    BFDLogger.logError("Failed to parse app hotkey '\(spec)' for \(app): \(error)")
                }
            }
            appHotkeys[app] = appMap
        }

        Task {
            JSONLogger.shared.log("bfd.config", data: [
                "hotkeys": globalHotkeys.count,
                "apps": appHotkeys.count,
                "blacklist": blacklist.count
            ])
        }
    }

    /// Start capturing keyboard events
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let handler = Unmanaged<BFDKeyHandler>.fromOpaque(refcon).takeUnretainedValue()
                return handler.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            JSONLogger.shared.log("bfd.err.tap", data: [:])
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let source = runLoopSource else {
            CFMachPortInvalidate(tap)
            eventTap = nil
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isEnabled = true
        JSONLogger.shared.log("bfd.start", data: [:])

        // [OBERDEBUG-004] Periodic health check every 30 seconds
        // Must dispatch to main thread to ensure timer is added to main run loop
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self = self, let tap = self.eventTap else {
                    Task { JSONLogger.shared.log("bfd.dbg.health", data: ["tap": "nil"]) }
                    return
                }
                let enabled = CGEvent.tapIsEnabled(tap: tap)
                let portValid = CFMachPortIsValid(tap)
                Task {
                    JSONLogger.shared.log("bfd.dbg.health", data: [
                        "enabled": enabled,
                        "portValid": portValid
                    ])
                }
            }
            // Fire immediately for first check
            self.healthCheckTimer?.fire()
        }

        return true
    }

    /// Restart the event tap (e.g. after sleep/wake)
    func restart() {
        guard let tap = eventTap else {
            JSONLogger.shared.log("bfd.wake.restart", msg: "no tap, starting fresh")
            _ = start()
            return
        }

        let valid = CFMachPortIsValid(tap)
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        JSONLogger.shared.log("bfd.wake.check", data: [
            "valid": valid,
            "enabled": enabled
        ])

        if !valid {
            JSONLogger.shared.log("bfd.wake.restart", msg: "tap invalid, recreating")
            stop()
            _ = start()
        } else if !enabled {
            JSONLogger.shared.log("bfd.wake.reenable", msg: "tap disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Temporarily suspend the event tap (e.g., while picker is visible)
    func suspend() {
        guard let tap = eventTap, CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        JSONLogger.shared.log("bfd.suspend")
    }

    /// Resume the event tap after suspension
    func resume() {
        guard let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        JSONLogger.shared.log("bfd.resume")
    }

    /// Stop capturing keyboard events
    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        guard let tap = eventTap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        CFMachPortInvalidate(tap)
        eventTap = nil
        isEnabled = false

        JSONLogger.shared.log("bfd.stop", data: [:])
    }

    // MARK: - Private

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // [OBERDEBUG-001] Log non-keyDown events (keyDown is too noisy)
        if type != .keyDown {
            Task {
                JSONLogger.shared.log("bfd.dbg.event", data: [
                    "type": type.rawValue,
                    "typeName": "\(type)"
                ])
            }
        }

        // Re-enable tap if disabled by timeout
        if type == .tapDisabledByTimeout {
            // [OBERDEBUG-002] Log timeout with tap state BEFORE re-enable
            let wasEnabled = eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            let wasValid = eventTap.map { CFMachPortIsValid($0) } ?? false
            Task {
                JSONLogger.shared.log("bfd.dbg.timeout", data: [
                    "wasEnabled": wasEnabled,
                    "wasValid": wasValid
                ])
            }

            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                // [OBERDEBUG-003] Log tap state AFTER re-enable attempt
                let nowEnabled = CGEvent.tapIsEnabled(tap: tap)
                let nowValid = CFMachPortIsValid(tap)
                Task {
                    JSONLogger.shared.log("bfd.dbg.reenable", data: [
                        "success": nowEnabled,
                        "valid": nowValid
                    ])
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Check for key repeat
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = bfdModifiersFromCGEvent(event.flags)
        // #47: the docs document blacklist/apps keys as bundle identifiers, but
        // the old code matched only localizedName, so doc-following configs
        // never matched. Resolve BOTH and match bundle id first, name as
        // back-compat.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier
        let appName = frontApp?.localizedName ?? ""

        // Check blacklist (bundle id or display name)
        if AppMatchPolicy.isBlacklisted(blacklist, bundleID: bundleID, name: appName) {
            return Unmanaged.passUnretained(event)
        }

        // Look up hotkey
        let eventKey = BFDHotkeyKey(modifiers: modifiers, keyCode: keyCode)

        // Check app-specific first (bundle id preferred, name fallback)
        if let appKey = AppMatchPolicy.resolveKey(Set(appHotkeys.keys), bundleID: bundleID, name: appName),
           let appBindings = appHotkeys[appKey] {
            for (configKey, appHk) in appBindings {
                if configKey.keyCode == eventKey.keyCode &&
                   bfdModifiersMatch(config: configKey.modifiers, event: eventKey.modifiers) {
                    switch appHk {
                    case .passthrough:
                        return Unmanaged.passUnretained(event)
                    case .command(let cmd):
                        let def = BFDHotkeyDef(run: cmd)
                        if shouldExecute(key: configKey, def: def, isRepeat: isRepeat) {
                            onHotkeyTriggered?("[\(appName)] app override", def)
                        }
                        return nil
                    case .extended(let def):
                        if shouldExecute(key: configKey, def: def, isRepeat: isRepeat) {
                            onHotkeyTriggered?("[\(appName)] app override", def)
                        }
                        return nil
                    }
                }
            }
        }

        // Check global hotkeys
        for (configKey, (spec, def)) in globalHotkeys {
            if configKey.keyCode == eventKey.keyCode &&
               bfdModifiersMatch(config: configKey.modifiers, event: eventKey.modifiers) {
                if shouldExecute(key: configKey, def: def, isRepeat: isRepeat) {
                    // [OBERDEBUG-005] Log hotkey execution
                    Task {
                        JSONLogger.shared.log("bfd.dbg.exec", data: [
                            "spec": spec,
                            "keyCode": keyCode
                        ])
                    }
                    onHotkeyTriggered?(spec, def)
                }
                return nil  // Consume event
            }
        }

        // No match, pass through
        return Unmanaged.passUnretained(event)
    }

    private func shouldExecute(key: BFDHotkeyKey, def: BFDHotkeyDef, isRepeat: Bool) -> Bool {
        guard let config = config else { return true }

        // Check repeat setting
        let allowRepeat = config.effectiveRepeat(for: def)
        if isRepeat && !allowRepeat {
            return false
        }

        // Check rate limit
        let allowRepeatForRateLimit = config.effectiveRepeat(for: def)
        // For repeat:false hotkeys, enforce a 100ms minimum gap to prevent OS
        // event batching from firing the same logical keypress twice.
        let minimumGap: Int = allowRepeatForRateLimit ? 0 : 100
        let rateLimit = max(config.effectiveRateLimit(for: def), minimumGap)
        let now = Date()

        lastExecutionTimeLock.lock()
        defer { lastExecutionTimeLock.unlock() }

        // Periodic cleanup: remove entries older than 1 minute to prevent unbounded growth
        // Only clean up every ~100 calls to avoid overhead
        if lastExecutionTime.count > 50 {
            let cutoff = now.addingTimeInterval(-60.0)
            lastExecutionTime = lastExecutionTime.filter { $0.value > cutoff }
        }

        if let lastTime = lastExecutionTime[key] {
            let elapsed = now.timeIntervalSince(lastTime) * 1000
            if elapsed < Double(rateLimit) {
                return false
            }
        }

        lastExecutionTime[key] = now
        return true
    }
}
