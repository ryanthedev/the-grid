# Phase 3 Pseudocode: Color + Mood Animations

## File 1: `grid-notify/Sources/GridNotify/ColorMoodAnimations.swift` (NEW)

```
import SwiftUI

// MARK: - Spacing / Type Scale (mirrors NotificationAnimations)

private enum CMSpace {
    xs = 4
    sm = 6
    md = 8
}

private enum CMTypeSize {
    body = 16
    meta = 12
}

// MARK: - Font Helper (mirrors NotificationAnimations)

private func berkeleyMono(size, weight = .regular) -> Font
    // Same pattern as other animation files: try BerkeleyMono Nerd Font, fall back to system monospaced


// MARK: - GradientSweepModifier (DW-3.1)
//
// On arrival, a horizontal linear gradient overlay sweeps left-to-right.
// The gradient moves from x=-1.0 to x=+1.0 over ~1.5s.
// Uses accent color at low opacity (~0.2) so it washes but doesn't obscure.
// After sweep completes, overlay disappears.

struct GradientSweepModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color

    @State sweepProgress: CGFloat = -1.0
    // Track whether the sweep animation has completed
    @State sweepDone: Bool = false

    func body(content):
        content
            .overlay:
                if isActive && !sweepDone:
                    // Full-width gradient overlay that slides from left to right
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, accentColor.opacity(0.2), accentColor.opacity(0.35), accentColor.opacity(0.2), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // Width is ~60% of container so it's a band, not full fill
                        .frame(width: geo.size.width * 0.6)
                        // Position: sweepProgress maps -1..1 to off-left..off-right
                        .offset(x: sweepProgress * geo.size.width)
                    }
                    .allowsHitTesting(false)
            .onAppear:
                if isActive:
                    startSweep()

    private func startSweep():
        sweepProgress = -0.6
        sweepDone = false
        withAnimation(.easeInOut(duration: 1.5)):
            sweepProgress = 1.0
        // Mark done after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5):
            sweepDone = true
}

extension View:
    func gradientSweep(isActive, accentColor) -> some View


// MARK: - HeatmapModifier (DW-3.2)
//
// Background color shifts from surface -> warm tint based on notification age.
// Age = seconds since notification.timestamp.
// Color ramp: 0s = normal surface, 60s+ = warm-shifted surface.
// Uses a very subtle overlay tint, not full background replacement.
// The color interpolates toward urgent color (warm) as age increases.
// Max warmth capped at 60s (older notifications all look the same).

struct HeatmapModifier: ViewModifier {
    let isActive: Bool
    // Notification age in seconds
    let age: TimeInterval
    let warmColor: Color

    // Max age before warmth plateaus
    private static let maxAge: TimeInterval = 60.0

    func body(content):
        content
            .overlay:
                if isActive:
                    Rectangle()
                        .fill(warmColor)
                        .opacity(warmthOpacity)
                        .allowsHitTesting(false)

    private var warmthOpacity: Double:
        // Clamp age 0..maxAge, map to 0..0.08 opacity
        let fraction = min(max(age, 0), Self.maxAge) / Self.maxAge
        return fraction * 0.08
}

extension View:
    func heatmap(isActive, age, warmColor) -> some View


// MARK: - NeonFlickerModifier (DW-3.3)
//
// For urgent notifications: the left border bar randomly dims and brightens.
// Creates a neon sign flicker aesthetic.
// Uses a timer to randomly toggle between dim and bright opacity.
// Applied as an overlay on top of the existing left-edge bar.
// Only active when notification.priority == .urgent.

struct NeonFlickerModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color

    @State flickerOpacity: Double = 1.0
    @State timer: Timer? = nil

    func body(content):
        content
            .overlay(alignment: .leading):
                if isActive:
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 3)
                        .opacity(flickerOpacity)
            .onAppear:
                if isActive:
                    startFlicker()
            .onChange(of: isActive):
                if isActive:
                    startFlicker()
                else:
                    stopFlicker()
            .onDisappear:
                timer?.invalidate()

    private func startFlicker():
        timer?.invalidate()
        // Random interval between 0.05-0.15s for erratic flicker
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            DispatchQueue.main.async:
                // Randomly choose dim (0.3) or bright (1.0) with bias toward bright
                if Double.random(in: 0...1) < 0.3:
                    flickerOpacity = Double.random(in: 0.2...0.5)
                else:
                    flickerOpacity = Double.random(in: 0.8...1.0)
        }

    private func stopFlicker():
        timer?.invalidate()
        timer = nil
        flickerOpacity = 1.0
}

extension View:
    func neonFlicker(isActive, accentColor) -> some View


// MARK: - ChromaticAberrationText (DW-3.4)
//
// During warning phase, title text gets an RGB split effect.
// Three copies of the text: red offset left, blue offset right, green centered.
// Small pixel offsets (1-2px) for subtle but visible effect.
// Uses ZStack with blend modes to simulate chromatic split.

struct ChromaticAberrationText: View {
    let text: String
    let font: Font
    let baseColor: Color
    // Offset in points for the R/B channels
    let offset: CGFloat

    var body: some View:
        ZStack:
            // Red channel — offset left
            Text(text)
                .font(font)
                .foregroundColor(Color.red.opacity(0.6))
                .offset(x: -offset, y: 0)
                .blendMode(.screen)
            // Blue channel — offset right
            Text(text)
                .font(font)
                .foregroundColor(Color.blue.opacity(0.6))
                .offset(x: offset, y: 0)
                .blendMode(.screen)
            // Green/base channel — centered (main readable text)
            Text(text)
                .font(font)
                .foregroundColor(baseColor)
}


// MARK: - AnimationEffect Structs

struct GradientSweepEffect: AnimationEffect {
    static let name = "gradient_sweep"
}

struct HeatmapEffect: AnimationEffect {
    static let name = "heatmap"
}

struct NeonFlickerEffect: AnimationEffect {
    static let name = "neon_flicker"
}

struct ChromaticAberrationEffect: AnimationEffect {
    static let name = "chromatic_aberration"
}
```

## File 2: `grid-notify/Sources/GridNotify/AnimationEngine.swift` (EDIT)

In `registerBuiltins()`, after Phase 2 registrations, add:

```
// Phase 3: color + mood animations
register(GradientSweepEffect())
register(HeatmapEffect())
register(NeonFlickerEffect())
register(ChromaticAberrationEffect())
```

Update the comment on `registerBuiltins()` to say "Phase 1 + Phase 2 + Phase 3".

## File 3: `grid-notify/Sources/GridNotify/NotificationPanelViews.swift` (EDIT)

### In NotificationItemView:

Add a computed property for notification age:
```
private var notificationAge: TimeInterval:
    return Date().timeIntervalSince(notification.timestamp)
```

### In titleView @ViewBuilder:

Before the final else (static text), add chromatic aberration case:
```
// After glitch check, before matrix_title check:
} else if isActive("chromatic_aberration") && phase == .warning {
    ChromaticAberrationText(
        text: displayTitle,
        font: berkeleyMono(size: TypeSize.body),
        baseColor: titleColor,
        offset: 1.5
    )
    .lineLimit(1)
    .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
}
```

### In body modifier chain:

After the scanline modifier (last Phase 2 modifier), add:
```
// Phase 3: color + mood animations
// Gradient sweep on arrival
.gradientSweep(isActive: isActive("gradient_sweep") && isArrival, accentColor: theme.accent)
// Heatmap age-based background tint
.heatmap(isActive: isActive("heatmap"), age: notificationAge, warmColor: theme.urgent)
// Neon flicker for urgent notifications
.neonFlicker(isActive: isActive("neon_flicker") && notification.priority == .urgent, accentColor: theme.accent)
```

## DW Coverage

| DW | Effect | Where Applied | Phase/Condition |
|----|--------|---------------|-----------------|
| DW-3.1 | gradient_sweep | body modifier chain | arrival |
| DW-3.2 | heatmap | body modifier chain | always (age-based) |
| DW-3.3 | neon_flicker | body modifier chain | urgent priority |
| DW-3.4 | chromatic_aberration | titleView @ViewBuilder | warning phase |
| DW-3.5 | all 4 in registerBuiltins() | AnimationEngine.swift | config-driven via isActive() |

## Build Validation

```bash
swift build --package-path grid-notify
```
