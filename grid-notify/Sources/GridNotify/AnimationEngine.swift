import SwiftUI

// MARK: - AnimationPhase

// Animation phases map to the conditions previously checked via hardcoded
// conditionals in NotificationItemView. Superset of LifecyclePhase: adds
// "arrival" (first 2s) and "ghost" (last 3s before expiry).
enum AnimationPhase: String, Codable, Hashable {
    case arrival
    case idle
    case nudge
    case warning
    case ghost
}

// MARK: - AnimationContext

// Context passed to every animation effect on each render.
// Provides lifecycle phase, notification data, and timing info.
struct AnimationContext {
    let phase: GridNotification.LifecyclePhase
    let animationPhase: AnimationPhase
    let isArrival: Bool
    let isRead: Bool
    let isPinned: Bool
    let ttl: TimeInterval
    let secondsRemaining: TimeInterval?
    let warnBefore: TimeInterval
    let warningProgress: Double
    let groupCount: Int
    let tick: UInt
    let theme: NotificationPanelTheme
}

// MARK: - AnimationEffect Protocol

// Protocol for all animation effects. Each effect wraps content with a
// ViewModifier or acts as a sentinel checked by the view layer.
// Effects that need @State (pulse, flash) are handled inline in the view;
// their protocol conformance is a no-op that serves as a registry entry.
protocol AnimationEffect {
    // Unique string name for registry lookup (e.g., "shake", "matrix_title")
    static var name: String { get }
}

// MARK: - AnimationRegistry

// Singleton registry mapping string names to animation effect instances.
// Effects register at startup. Config references effects by name.
final class AnimationRegistry {
    static let shared = AnimationRegistry()

    private var effects: [String: AnimationEffect] = [:]

    private init() {}

    // Register an effect. Called at startup for all built-in effects.
    func register(_ effect: AnimationEffect) {
        effects[type(of: effect).name] = effect
    }

    // Look up effect by name. Returns nil for unknown names.
    func effect(named name: String) -> AnimationEffect? {
        return effects[name]
    }

    // All registered effect names, sorted.
    var registeredNames: [String] {
        return effects.keys.sorted()
    }

    // Register all built-in effects (Phase 1 + Phase 2 + Phase 3 + Phase 4).
    func registerBuiltins() {
        // Phase 1: core animations
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

        // Phase 2: text + spatial animations
        register(GlitchEffect())
        register(RedactEffect())
        register(TypingIndicatorEffect())
        register(ScanlineEffect())
        register(BounceEffect())
        register(AccordionEffect())
        register(TiltEffect())
        register(ParallaxEffect())

        // Phase 3: color + mood animations
        register(GradientSweepEffect())
        register(HeatmapEffect())
        register(NeonFlickerEffect())
        register(ChromaticAberrationEffect())

        // Phase 4: progress + terminal animations
        register(HourglassSpriteEffect())
        register(PieCountdownEffect())
        register(HeartbeatEffect())
        register(DissolveEffect())
        register(CursorBlinkEffect())
        register(BootSequenceEffect())
        register(StackTraceEffect())
        register(ASCIIBorderEffect())
    }
}

// MARK: - Built-in Effect Wrappers

// Each existing animation gets a lightweight struct conforming to AnimationEffect.
// The original View/ViewModifier implementations stay unchanged.

struct ShakeEffect: AnimationEffect {
    static let name = "shake"
}

struct BreathingEffect: AnimationEffect {
    static let name = "breathing"
}

struct SlideInEffect: AnimationEffect {
    static let name = "slide_in"
}

struct GrowEffect: AnimationEffect {
    static let name = "grow"
}

struct BorderStrobeEffect: AnimationEffect {
    static let name = "border_strobe"
}

struct FadeToGhostEffect: AnimationEffect {
    static let name = "fade_to_ghost"
}

struct MatrixTitleEffect: AnimationEffect {
    static let name = "matrix_title"
}

struct WaveTitleEffect: AnimationEffect {
    static let name = "wave_title"
}

struct ProgressBarEffect: AnimationEffect {
    static let name = "progress_bar"
}

struct WarningPulseEffect: AnimationEffect {
    static let name = "warning_pulse"
}

struct ArrivalFlashEffect: AnimationEffect {
    static let name = "arrival_flash"
}

struct SpinnerEffect: AnimationEffect {
    static let name = "spinner"
}

// MARK: - Phase Computation

// Computes the current AnimationPhase from notification state.
// Replaces scattered isArrival / phase == .warning / remaining < 3 checks.
func computeAnimationPhase(
    notification: GridNotification,
    isArrival: Bool
) -> AnimationPhase {
    if isArrival { return .arrival }
    let lifecycle = notification.lifecyclePhase()
    if lifecycle == .warning { return .warning }
    if lifecycle == .nudge { return .nudge }
    // Ghost: in the last 3 seconds before expiry
    if let remaining = notification.secondsRemaining(), remaining < 3.0, remaining > 0 {
        return .ghost
    }
    return .idle
}

// MARK: - Animation Active Check

// Checks whether a named animation is active for the current notification and phase.
func isAnimationActive(
    _ name: String,
    config: AnimationConfig,
    notification: GridNotification,
    animationPhase: AnimationPhase
) -> Bool {
    // During nudge phase, use the notification's nudge animations instead of config
    if animationPhase == .nudge, let nudge = notification.nudge {
        return nudge.animations.contains(name)
    }
    let activeNames = config.activeAnimations(
        source: notification.source,
        phase: animationPhase,
        overrides: notification.animationOverride
    )
    return activeNames.contains(name)
}
