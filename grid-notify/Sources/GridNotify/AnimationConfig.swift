import Foundation
import Yams

// MARK: - AnimationPreset

// Defines which animations are active during each phase.
// Missing phase key means empty list (no animations for that phase).
struct AnimationPreset: Codable {
    var arrival: [String]?
    var idle: [String]?
    var warning: [String]?
    var ghost: [String]?

    // Returns animation names for a given phase.
    func names(for phase: AnimationPhase) -> [String] {
        switch phase {
        case .arrival: return arrival ?? []
        case .idle: return idle ?? []
        case .nudge: return idle ?? []
        case .warning: return warning ?? []
        case .ghost: return ghost ?? []
        }
    }
}

// MARK: - AnimationConfig

// Runtime animation configuration. Resolved from YAML presets and
// per-notification JSON overrides.
struct AnimationConfig {
    // Default preset applied when no source-specific preset matches.
    var defaultPreset: AnimationPreset

    // Source-specific presets (key = notification source string).
    var sourcePresets: [String: AnimationPreset]

    // Resolve which animations are active for a notification in a given phase.
    // Priority: per-notification override > source preset > default preset.
    func activeAnimations(
        source: String,
        phase: AnimationPhase,
        overrides: NotificationAnimationOverride?
    ) -> [String] {
        // Per-notification override takes highest priority
        if let overrides = overrides {
            let names = overrides.names(for: phase)
            if !names.isEmpty { return names }
        }
        // Source-specific preset
        if let sourcePreset = sourcePresets[source] {
            let names = sourcePreset.names(for: phase)
            if !names.isEmpty { return names }
        }
        // Default preset
        return defaultPreset.names(for: phase)
    }

    // Built-in defaults that reproduce current hardcoded behavior.
    static let builtinDefault = AnimationConfig(
        defaultPreset: AnimationPreset(
            arrival: ["slide_in", "matrix_title", "arrival_flash", "fade_to_ghost", "spinner", "breathing"],
            idle: ["wave_title", "spinner", "breathing", "fade_to_ghost"],
            warning: ["shake", "grow", "border_strobe", "warning_pulse", "progress_bar", "spinner", "fade_to_ghost"],
            ghost: ["fade_to_ghost", "wave_title", "spinner", "breathing"]
        ),
        sourcePresets: [
            "imessage": AnimationPreset(
                arrival: ["slide_in", "matrix_title", "arrival_flash", "fade_to_ghost", "spinner", "breathing", "bounce"],
                idle: ["wave_title", "spinner", "breathing", "fade_to_ghost"],
                warning: ["glitch", "shake", "progress_bar", "spinner", "fade_to_ghost"],
                ghost: ["fade_to_ghost"]
            ),
            "generic": AnimationPreset(
                arrival: ["slide_in", "matrix_title", "arrival_flash", "fade_to_ghost", "spinner", "breathing"],
                idle: ["wave_title", "spinner", "breathing", "fade_to_ghost"],
                warning: ["shake", "grow", "border_strobe", "warning_pulse", "progress_bar", "spinner", "fade_to_ghost"],
                ghost: ["fade_to_ghost"]
            ),
            "ci": AnimationPreset(
                arrival: ["slide_in", "boot_sequence", "spinner", "breathing"],
                idle: ["spinner", "breathing"],
                warning: ["stack_trace", "progress_bar", "shake", "spinner"],
                ghost: ["fade_to_ghost"]
            ),
            "urgent": AnimationPreset(
                arrival: ["slide_in", "neon_flicker", "spinner", "breathing"],
                idle: ["heartbeat", "spinner", "breathing", "fade_to_ghost"],
                warning: ["dissolve", "warning_pulse", "progress_bar", "spinner", "fade_to_ghost"],
                ghost: ["fade_to_ghost"]
            )
        ]
    )
}

// MARK: - YAML Decoding Structs

// Private structs for YAML parsing.
// These mirror the YAML structure inside notify.yaml:
//
//   animations:
//     default:
//       arrival: [slide_in, matrix_title, arrival_flash]
//       idle: [wave_title, spinner, breathing]
//       warning: [shake, grow, border_strobe, warning_pulse, progress_bar, spinner]
//       ghost: [fade_to_ghost]
//     sources:
//       imessage:
//         arrival: [slide_in, matrix_title]
//         idle: [wave_title]
//         warning: [shake, border_strobe]
//         ghost: [fade_to_ghost]

struct AnimationConfigYAML: Codable {
    var default_: AnimationPresetYAML?
    var sources: [String: AnimationPresetYAML]?

    enum CodingKeys: String, CodingKey {
        case default_ = "default"
        case sources
    }
}

struct AnimationPresetYAML: Codable {
    var arrival: [String]?
    var idle: [String]?
    var warning: [String]?
    var ghost: [String]?
}

// MARK: - YAML Loader

// Parse animation config from notify.yaml.
// Returns builtinDefault if file missing or animations section absent.
func loadAnimationConfigFromYAML() -> AnimationConfig {
    let configPath = "\(XDG.configHome)/thegrid/notify.yaml"
    guard FileManager.default.fileExists(atPath: configPath) else {
        return .builtinDefault
    }
    do {
        let yamlString = try String(contentsOfFile: configPath, encoding: .utf8)
        let decoder = YAMLDecoder()
        let fullConfig = try decoder.decode(NotifyConfigAnimationsOnly.self, from: yamlString)
        guard let animYAML = fullConfig.animations else {
            return .builtinDefault
        }
        return parseAnimationConfig(animYAML)
    } catch {
        jlog("err.notify.animcfg.parse", data: ["err": "\(error)"])
        return .builtinDefault
    }
}

// Minimal YAML struct that only extracts the animations key.
// Avoids re-parsing the entire NotifyConfigYAML.
private struct NotifyConfigAnimationsOnly: Codable {
    var animations: AnimationConfigYAML?
}

private func parseAnimationConfig(_ yaml: AnimationConfigYAML) -> AnimationConfig {
    var config = AnimationConfig.builtinDefault

    if let defaultYAML = yaml.default_ {
        config.defaultPreset = AnimationPreset(
            arrival: defaultYAML.arrival,
            idle: defaultYAML.idle,
            warning: defaultYAML.warning,
            ghost: defaultYAML.ghost
        )
    }

    if let sources = yaml.sources {
        for (source, presetYAML) in sources {
            config.sourcePresets[source] = AnimationPreset(
                arrival: presetYAML.arrival,
                idle: presetYAML.idle,
                warning: presetYAML.warning,
                ghost: presetYAML.ghost
            )
        }
    }

    return config
}

// MARK: - AnimationConfigWatcher (Hot-Reload)

// Watches notify.yaml for changes and reloads AnimationConfig.
// Uses DispatchSource.makeFileSystemObjectSource, same pattern as
// NotificationFileWatcher for pipe/file watching.
class AnimationConfigWatcher {
    private let configPath: String
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.thegrid.notify.animconfig")
    private var isRunning: Bool = false

    // Callback invoked on main thread when config changes.
    var onConfigChange: ((AnimationConfig) -> Void)?

    init() {
        configPath = "\(XDG.configHome)/thegrid/notify.yaml"
    }

    func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
        }
        queue.async {
            self.watchFile()
        }
        jlog("notify.animcfg.watcher.start", data: ["path": configPath])
    }

    func stop() {
        queue.sync {
            isRunning = false
            tearDown()
        }
        jlog("notify.animcfg.watcher.stop")
    }

    private func watchFile() {
        guard isRunning else { return }

        let openFD = open(configPath, O_RDONLY | O_EVTONLY)
        guard openFD >= 0 else {
            // File doesn't exist yet; retry after delay
            jlog("notify.animcfg.nofile", data: ["path": configPath])
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.watchFile()
            }
            return
        }
        fd = openFD

        let events: DispatchSource.FileSystemEvent = [.write, .delete, .rename]
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: events,
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleChange()
        }
        src.resume()
        source = src
        jlog("notify.animcfg.watch", data: ["path": configPath])
    }

    private func handleChange() {
        guard isRunning else { return }
        let events = source?.data ?? 0
        let eventMask = DispatchSource.FileSystemEvent(rawValue: events)

        if eventMask.contains(.delete) || eventMask.contains(.rename) {
            // File was replaced (e.g., atomic write with rename).
            tearDown()
            // Brief delay to let the new file settle
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.reloadAndNotify()
                self.watchFile()
            }
        } else {
            // .write event: file was modified in place
            reloadAndNotify()
        }
    }

    private func reloadAndNotify() {
        let config = loadAnimationConfigFromYAML()
        DispatchQueue.main.async { [weak self] in
            self?.onConfigChange?(config)
        }
        jlog("notify.animcfg.reload")
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
