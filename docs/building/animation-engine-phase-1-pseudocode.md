# Pseudocode: Animation Engine Phase 1

## DW Coverage Map

| DW | Section |
|----|---------|
| DW-1.1 | 1. AnimationEffect Protocol |
| DW-1.2 | 2. AnimationRegistry |
| DW-1.3 | 3. AnimationConfig YAML |
| DW-1.4 | 4. Per-Notification JSON Overrides |
| DW-1.5 | 5. Hot-Reload File Watcher |
| DW-1.6 | 6. Migrate Existing Animations |
| DW-1.7 | 7. AnimatedNotificationView |
| DW-1.8 | 8. Preserve Visual Behavior |

---

## File: AnimationEngine.swift (NEW)

### 1. AnimationEffect Protocol [DW-1.1]

```
// Context passed to every animation effect on each render.
// Provides lifecycle phase, notification data, and timing info.
struct AnimationContext {
    let phase: GridNotification.LifecyclePhase
    let isArrival: Bool        // arrived within last 2 seconds
    let isRead: Bool
    let isPinned: Bool
    let ttl: TimeInterval
    let secondsRemaining: TimeInterval?
    let warnBefore: TimeInterval
    let warningProgress: Double  // 1.0 = full, 0.0 = drained
    let groupCount: Int
    let tick: UInt              // lifecycle tick from VM, changes each second
    let theme: NotificationPanelTheme
}

// Protocol for all animation effects.
// Each effect wraps content with a ViewModifier or replaces content.
// Effects self-report which phases they activate in.
protocol AnimationEffect {
    // Unique string name for registry lookup (e.g., "shake", "matrix")
    static var name: String { get }

    // Which lifecycle phases this effect activates in.
    // Empty set = always active (e.g., fadeToGhost checks internally).
    static var activePhases: Set<AnimationPhase> { get }

    // Apply the effect to content given the current context.
    // Returns modified view wrapped in AnyView for dynamic composition.
    @ViewBuilder
    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView
}

// Animation phases (superset of LifecyclePhase, adds "arrival" and "ghost").
// These map to the conditions currently checked in NotificationItemView.
enum AnimationPhase: String, Codable, Hashable {
    case arrival   // first 2 seconds after notification arrives
    case idle      // normal phase, not arrival, not warning
    case warning   // TTL warning phase
    case ghost     // last N seconds before expiry (fadeToGhost territory)
}
```

### 2. AnimationRegistry [DW-1.2]

```
// Singleton registry mapping string names to animation effect instances.
// Effects register at startup. Config references effects by name.
class AnimationRegistry {
    static let shared = AnimationRegistry()

    // name -> effect instance
    private var effects: [String: AnimationEffect] = [:]

    // Register an effect. Called at startup for all built-in effects.
    func register(_ effect: AnimationEffect) {
        effects[type(of: effect).name] = effect
    }

    // Look up effect by name. Returns nil for unknown names.
    func effect(named name: String) -> AnimationEffect? {
        return effects[name]
    }

    // All registered effect names (for help view, validation).
    var registeredNames: [String] {
        return effects.keys.sorted()
    }

    // Register all built-in effects.
    // Called once from AppDelegate on startup.
    func registerBuiltins() {
        // Phase 1 migrations (existing 12 animations)
        register(ShakeEffect())
        register(BreathingEffect())
        register(SlideInEffect())
        register(GrowEffect())
        register(BorderStrobeEffect())
        register(FadeToGhostEffect())
        register(MatrixTitleEffect())
        register(WaveTitleEffect())
        register(ProgressBarEffect())
        register(WarningPulseEffect())
        register(ArrivalFlashEffect())
        register(SpinnerEffect())
    }
}
```

### 3. AnimationConfig (YAML model) [DW-1.3]

```
// YAML structure for animation presets.
// Lives inside notify.yaml under an "animations" key.
//
// Example YAML:
//   animations:
//     default:
//       arrival: [slide_in, matrix_title, arrival_flash]
//       idle: [wave_title, spinner, breathing]
//       warning: [shake, grow, border_strobe, warning_pulse, progress_bar]
//       ghost: [fade_to_ghost]
//     sources:
//       imessage:
//         arrival: [slide_in, matrix_title, arrival_flash]
//         idle: [wave_title, spinner]
//         warning: [shake, grow, border_strobe, progress_bar]
//         ghost: [fade_to_ghost]

struct AnimationPreset: Codable {
    // Animation names active during each phase.
    // Missing phase key = empty list (no animations for that phase).
    var arrival: [String]?
    var idle: [String]?
    var warning: [String]?
    var ghost: [String]?

    // Returns animation names for a given phase.
    func names(for phase: AnimationPhase) -> [String] {
        switch phase {
        case .arrival: return arrival ?? []
        case .idle: return idle ?? []
        case .warning: return warning ?? []
        case .ghost: return ghost ?? []
        }
    }
}

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
            arrival: ["slide_in", "matrix_title", "arrival_flash"],
            idle: ["wave_title", "spinner", "breathing"],
            warning: ["shake", "grow", "border_strobe", "warning_pulse", "progress_bar", "spinner"],
            ghost: ["fade_to_ghost"]
        ),
        sourcePresets: [:]
    )
}

// YAML decoding structs (private, mirror NotifyConfig pattern)
private struct AnimationConfigYAML: Codable {
    var default_: AnimationPresetYAML?
    var sources: [String: AnimationPresetYAML]?

    enum CodingKeys: String, CodingKey {
        case default_ = "default"
        case sources
    }
}

private struct AnimationPresetYAML: Codable {
    var arrival: [String]?
    var idle: [String]?
    var warning: [String]?
    var ghost: [String]?
}
```

## File: NotifyConfig.swift (MODIFY)

### 3b. Add animations field to NotifyConfig

```
// Add to NotifyConfig struct:
var animations: AnimationConfig

// Add to NotifyConfig.init:
// animations: AnimationConfig = .builtinDefault

// Add to NotifyConfigYAML:
// var animations: AnimationConfigYAML?

// In loadNotifyConfig(), parse animations section:
// if let animYAML = yaml.animations {
//     parse into AnimationConfig, merging with builtinDefault
// }
```

## File: Notification.swift (MODIFY)

### 4. Per-Notification JSON Overrides [DW-1.4]

```
// Add to GridNotification:
// Per-notification animation override. nil = use config defaults.
var animationOverride: NotificationAnimationOverride?

// The override struct (Codable for JSON persistence):
struct NotificationAnimationOverride: Codable {
    var arrival: [String]?
    var idle: [String]?
    var warning: [String]?
    var ghost: [String]?

    func names(for phase: AnimationPhase) -> [String] {
        switch phase {
        case .arrival: return arrival ?? []
        case .idle: return idle ?? []
        case .warning: return warning ?? []
        case .ghost: return ghost ?? []
        }
    }
}

// Add to GridNotification.init:
// animationOverride: NotificationAnimationOverride? = nil

// Add to NotificationLineDescriptor (in NotificationFileWatcher.swift):
// let animations: NotificationAnimationOverride?

// In processLine(), pass animations from descriptor to GridNotification:
// animationOverride: desc.animations
```

## File: AnimationConfig.swift (NEW)

### 5. Hot-Reload File Watcher [DW-1.5]

```
// Watches notify.yaml for changes and reloads AnimationConfig.
// Uses DispatchSource.makeFileSystemObjectSource (same pattern as NotificationFileWatcher).
class AnimationConfigWatcher {
    private let configPath: String
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.thegrid.notify.animconfig")

    // Callback invoked on main thread when config changes.
    var onConfigChange: ((AnimationConfig) -> Void)?

    init() {
        configPath = "\(XDG.configHome)/thegrid/notify.yaml"
    }

    func start() {
        queue.async {
            self.watchFile()
        }
    }

    func stop() {
        queue.sync {
            self.tearDown()
        }
    }

    private func watchFile() {
        let openFD = open(configPath, O_RDONLY | O_EVTONLY)
        guard openFD >= 0 else {
            // File doesn't exist yet; retry after delay
            jlog("notify.animcfg.nofile", data: ["path": configPath])
            queue.asyncAfter(deadline: .now() + 5) {
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
        let events = source?.data ?? 0
        let eventMask = DispatchSource.FileSystemEvent(rawValue: events)

        if eventMask.contains(.delete) || eventMask.contains(.rename) {
            // File was replaced (e.g., atomic write with rename).
            // Tear down current watcher and re-open.
            tearDown()
            // Brief delay to let the new file settle
            queue.asyncAfter(deadline: .now() + 0.2) {
                self.reloadAndNotify()
                self.watchFile()
            }
        } else {
            // .write event — file was modified in place
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
        let yaml = try decoder.decode(NotifyConfigYAML.self, from: yamlString)
        // NotifyConfigYAML already has animations field
        guard let animYAML = yaml.animations else {
            return .builtinDefault
        }
        return parseAnimationConfig(animYAML)
    } catch {
        jlog("err.notify.animcfg.parse", data: ["err": "\(error)"])
        return .builtinDefault
    }
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
```

## File: NotificationAnimations.swift (MODIFY)

### 6. Migrate Existing Animations [DW-1.6]

Each existing animation gets a wrapper struct conforming to AnimationEffect.
The original View/ViewModifier structs stay as-is (they work). The wrapper
just bridges them to the protocol.

```
// --- ShakeEffect ---
struct ShakeEffect: AnimationEffect {
    static let name = "shake"
    static let activePhases: Set<AnimationPhase> = [.warning]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        let isActive = context.phase == .warning
        return AnyView(content.shake(isActive: isActive, tick: context.tick))
    }
}

// --- BreathingEffect ---
struct BreathingEffect: AnimationEffect {
    static let name = "breathing"
    static let activePhases: Set<AnimationPhase> = [.idle]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // Breathing is applied to the spinner, not the whole row.
        // This effect is a no-op at the row level.
        // The spinner component checks config internally.
        return AnyView(content)
    }
}

// --- SlideInEffect ---
struct SlideInEffect: AnimationEffect {
    static let name = "slide_in"
    static let activePhases: Set<AnimationPhase> = [.arrival]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        return AnyView(content.slideIn(isActive: context.isArrival))
    }
}

// --- GrowEffect ---
struct GrowEffect: AnimationEffect {
    static let name = "grow"
    static let activePhases: Set<AnimationPhase> = [.warning]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        return AnyView(content.grow(isActive: context.phase == .warning))
    }
}

// --- BorderStrobeEffect ---
struct BorderStrobeEffect: AnimationEffect {
    static let name = "border_strobe"
    static let activePhases: Set<AnimationPhase> = [.warning]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        return AnyView(
            content.borderStrobe(
                isActive: context.phase == .warning,
                urgentColor: context.theme.urgent,
                accentColor: context.theme.accent
            )
        )
    }
}

// --- FadeToGhostEffect ---
struct FadeToGhostEffect: AnimationEffect {
    static let name = "fade_to_ghost"
    static let activePhases: Set<AnimationPhase> = [.ghost]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        return AnyView(
            content.fadeToGhost(secondsRemaining: context.secondsRemaining)
        )
    }
}

// --- MatrixTitleEffect ---
// This is a content-replacement effect (replaces title Text with MatrixText).
// It's handled specially in the title rendering, not as a ViewModifier on the row.
struct MatrixTitleEffect: AnimationEffect {
    static let name = "matrix_title"
    static let activePhases: Set<AnimationPhase> = [.arrival]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // No-op at row level. Title rendering checks config for this.
        return AnyView(content)
    }
}

// --- WaveTitleEffect ---
// Content-replacement effect for title text.
struct WaveTitleEffect: AnimationEffect {
    static let name = "wave_title"
    static let activePhases: Set<AnimationPhase> = [.idle]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // No-op at row level. Title rendering checks config for this.
        return AnyView(content)
    }
}

// --- ProgressBarEffect ---
// Content-insertion effect (adds progress bar below body text).
struct ProgressBarEffect: AnimationEffect {
    static let name = "progress_bar"
    static let activePhases: Set<AnimationPhase> = [.warning]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // No-op at row level. Body section checks config for this.
        return AnyView(content)
    }
}

// --- WarningPulseEffect ---
struct WarningPulseEffect: AnimationEffect {
    static let name = "warning_pulse"
    static let activePhases: Set<AnimationPhase> = [.warning]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // Handled inline in AnimatedNotificationView (needs @State).
        return AnyView(content)
    }
}

// --- ArrivalFlashEffect ---
struct ArrivalFlashEffect: AnimationEffect {
    static let name = "arrival_flash"
    static let activePhases: Set<AnimationPhase> = [.arrival]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // Handled inline in AnimatedNotificationView (needs @State).
        return AnyView(content)
    }
}

// --- SpinnerEffect ---
// Controls the braille spinner in priorityEdge.
struct SpinnerEffect: AnimationEffect {
    static let name = "spinner"
    static let activePhases: Set<AnimationPhase> = [.idle, .warning]

    func apply<V: View>(to content: V, context: AnimationContext) -> AnyView {
        // No-op at row level. priorityEdge checks config for this.
        return AnyView(content)
    }
}
```

## File: NotificationPanelViews.swift (MODIFY)

### 7. AnimatedNotificationView [DW-1.7]

Replace NotificationItemView's hardcoded conditionals with config-driven logic.

```
// NotificationItemView changes:
// - Accept animationConfig: AnimationConfig parameter
// - Compute current AnimationPhase from notification state
// - Query config for active animation names
// - Use animation names to decide what to render

// Current AnimationPhase computation (replaces scattered conditionals):
func computePhase(notification, isArrival) -> AnimationPhase {
    if isArrival { return .arrival }
    let lifecycle = notification.lifecyclePhase()
    if lifecycle == .warning { return .warning }
    // Ghost: in the last fadeStartSeconds (3s) before expiry
    if let remaining = notification.secondsRemaining(), remaining < 3.0 {
        return .ghost
    }
    return .idle
}

// Build AnimationContext from notification + view state:
func buildContext(notification, phase, isArrival, tick, theme) -> AnimationContext {
    return AnimationContext(
        phase: notification.lifecyclePhase(),
        isArrival: isArrival,
        isRead: notification.isRead,
        isPinned: notification.isPinned,
        ttl: notification.ttl,
        secondsRemaining: notification.secondsRemaining(),
        warnBefore: notification.warnBefore,
        warningProgress: computeWarningProgress(notification),
        groupCount: notification.groupCount,
        tick: tick,
        theme: theme
    )
}

// Check if a named animation is active for the current phase:
func isAnimationActive(name: String, config: AnimationConfig, notification, phase, overrides) -> Bool {
    let activeNames = config.activeAnimations(
        source: notification.source,
        phase: phase,
        overrides: notification.animationOverride
    )
    return activeNames.contains(name)
}

// --- Modified titleView ---
// Instead of: if isArrival { MatrixText } else if !isRead && phase == .normal { WaveText } else { Text }
// Now:
@ViewBuilder
var titleView: some View {
    let animPhase = computePhase(notification, isArrival)
    let activeNames = config.activeAnimations(source: notification.source, phase: animPhase, overrides: notification.animationOverride)
    let titleColor = notification.isRead ? theme.textSecondary : theme.textPrimary

    if activeNames.contains("matrix_title") && isArrival {
        MatrixText(text: displayTitle, font: ..., color: titleColor, duration: 0.8)
    } else if activeNames.contains("wave_title") && !notification.isRead {
        WaveText(text: displayTitle, font: ..., color: titleColor, amplitude: 1.0, cycleDuration: 2.0)
    } else {
        Text(displayTitle).font(...).foregroundColor(titleColor)
    }
}

// --- Modified body section ---
// ProgressBar now gated on config:
if isAnimationActive("progress_bar", ...) && phase == .warning {
    ProgressBarView(progress: warningProgress, ...)
}

// --- Modified priorityEdge ---
// Spinner gated on config:
if isAnimationActive("spinner", ...) {
    if phase == .warning {
        SpriteView(frames: countdownFrames, interval: 0.2, color: theme.urgent)
    } else if !notification.isRead {
        SpriteView(frames: spinnerFrames, interval: 0.1, color: theme.accent)
            .breathing(isActive: isAnimationActive("breathing", ...))
    }
} else {
    Text(symbol).font(...).foregroundColor(color)
}

// --- Modified row modifiers ---
// Each modifier gated on config:
.grow(isActive: isAnimationActive("grow", ...) && phase == .warning)
.overlay(warningPulseOverlay if isAnimationActive("warning_pulse", ...))
.overlay(flashOverlay if isAnimationActive("arrival_flash", ...))
.borderStrobe(isActive: isAnimationActive("border_strobe", ...) && phase == .warning, ...)
.shake(isActive: isAnimationActive("shake", ...) && phase == .warning, tick: tick)
.fadeToGhost(secondsRemaining: isAnimationActive("fade_to_ghost", ...) ? remaining : nil)
.slideIn(isActive: isAnimationActive("slide_in", ...) && isArrival)

// Body text color also gated:
// Only use textPrimary in warning if warning_pulse is active
let bodyColor = (isAnimationActive("warning_pulse", ...) && phase == .warning)
    ? theme.textPrimary : theme.textSecondary

// Countdown timer in title row also gated:
// Show countdown when any warning animation is active
if phase == .warning && hasAnyWarningAnimation {
    Text("\(remaining)s") in urgent color
}
```

### 8. ViewModel Changes [DW-1.7 continued]

```
// Add to NotificationPanelViewModel:
@Published var animationConfig: AnimationConfig = .builtinDefault

// Method to update animation config (called by hot-reload):
func updateAnimationConfig(_ config: AnimationConfig) {
    self.animationConfig = config
}

// NotificationListView passes config down:
NotificationItemView(
    notification: notification,
    isSelected: ...,
    isVisualSelected: ...,
    theme: viewModel.theme,
    tick: viewModel.lifecycleTick,
    animationConfig: viewModel.animationConfig  // NEW
)
```

### 8b. AppDelegate Wiring [DW-1.5]

```
// In AppDelegate:
private var animConfigWatcher: AnimationConfigWatcher?

// In applicationDidFinishLaunching:
// After creating viewModel:
AnimationRegistry.shared.registerBuiltins()

let animConfig = loadAnimationConfigFromYAML()
vm.updateAnimationConfig(animConfig)

let watcher = AnimationConfigWatcher()
watcher.onConfigChange = { [weak vm] config in
    vm?.updateAnimationConfig(config)
    jlog("notify.animcfg.applied")
}
watcher.start()
self.animConfigWatcher = watcher

// In applicationWillTerminate:
animConfigWatcher?.stop()
```

## Summary of Changes by File

### New Files
- `AnimationEngine.swift`: AnimationEffect protocol, AnimationPhase enum, AnimationContext, AnimationRegistry, all 12 effect wrappers
- `AnimationConfig.swift`: AnimationConfig, AnimationPreset, AnimationConfigWatcher, loadAnimationConfigFromYAML()

### Modified Files
- `Notification.swift`: Add NotificationAnimationOverride struct, add animationOverride field to GridNotification
- `NotificationFileWatcher.swift`: Add animations field to NotificationLineDescriptor, pass to GridNotification
- `NotifyConfig.swift`: Add animations field to NotifyConfigYAML (for initial load), add AnimationConfigYAML/AnimationPresetYAML structs
- `NotificationPanelViews.swift`: NotificationItemView accepts animationConfig, replaces all hardcoded phase conditionals with config-driven checks
- `NotificationPanelViewModel.swift`: Add @Published animationConfig, updateAnimationConfig method
- `AppDelegate.swift`: Register builtins, load initial config, start watcher, wire callback
- `NotificationAnimations.swift`: Add AnimationEffect conformance wrappers for all 12 existing animations

### Unchanged Files
- `NotificationPanelTheme.swift`
- `NotificationPanelWindow.swift`
- `NotificationStore.swift`
- `NotificationSourceConfig.swift`
- All existing animation View/ViewModifier structs (they stay as-is, wrapped by effect protocol)
