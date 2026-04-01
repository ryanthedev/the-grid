import SwiftUI

// MARK: - Spacing / Type Scale (mirrors NotificationAnimations)

private enum CMSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
}

private enum CMTypeSize {
    static let body: CGFloat = 16
    static let meta: CGFloat = 12
}

// MARK: - Font Helper (mirrors NotificationAnimations)

private func berkeleyMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - GradientSweepModifier (DW-3.1)

// On arrival, a horizontal gradient band sweeps left-to-right across the row.
// The band is ~60% of container width, accent color at low opacity.
// After the 1.5s sweep completes, the overlay disappears.
struct GradientSweepModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color

    @State private var sweepProgress: CGFloat = -0.6
    // Whether the sweep animation has completed
    @State private var sweepDone: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !sweepDone {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                accentColor.opacity(0.2),
                                accentColor.opacity(0.35),
                                accentColor.opacity(0.2),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // Band width is ~60% of container
                        .frame(width: geo.size.width * 0.6)
                        // sweepProgress maps -0.6..1.0 to off-left..off-right
                        .offset(x: sweepProgress * geo.size.width)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                if isActive {
                    startSweep()
                }
            }
    }

    private func startSweep() {
        sweepProgress = -0.6
        sweepDone = false
        withAnimation(.easeInOut(duration: 1.5)) {
            sweepProgress = 1.0
        }
        // Mark done after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sweepDone = true
        }
    }
}

extension View {
    func gradientSweep(isActive: Bool, accentColor: Color) -> some View {
        modifier(GradientSweepModifier(isActive: isActive, accentColor: accentColor))
    }
}

// MARK: - HeatmapModifier (DW-3.2)

// Background tint shifts toward warm color based on notification age.
// Age 0s = no tint. Age 60s+ = max warmth (capped at 0.08 opacity).
// Creates subtle visual distinction between fresh and old notifications.
struct HeatmapModifier: ViewModifier {
    let isActive: Bool
    // Notification age in seconds
    let age: TimeInterval
    let warmColor: Color

    // Age at which warmth plateaus
    private static let maxAge: TimeInterval = 60.0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    Rectangle()
                        .fill(warmColor)
                        .opacity(warmthOpacity)
                        .allowsHitTesting(false)
                }
            }
    }

    private var warmthOpacity: Double {
        // Clamp age 0..maxAge, map to 0..0.08 opacity
        let fraction = min(max(age, 0), Self.maxAge) / Self.maxAge
        return fraction * 0.08
    }
}

extension View {
    func heatmap(isActive: Bool, age: TimeInterval, warmColor: Color) -> some View {
        modifier(HeatmapModifier(isActive: isActive, age: age, warmColor: warmColor))
    }
}

// MARK: - NeonFlickerModifier (DW-3.3)

// For urgent notifications: left border bar randomly dims and brightens.
// Creates a neon sign flicker aesthetic with erratic timing.
// 70% of ticks are bright (0.8-1.0), 30% are dim (0.2-0.5).
struct NeonFlickerModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color

    @State private var flickerOpacity: Double = 1.0
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 3)
                        .opacity(flickerOpacity)
                }
            }
            .onAppear {
                if isActive {
                    startFlicker()
                }
            }
            .onChange(of: isActive) { active in
                if active {
                    startFlicker()
                } else {
                    stopFlicker()
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startFlicker() {
        timer?.invalidate()
        // ~12fps erratic flicker
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            DispatchQueue.main.async {
                // 30% chance of dim, 70% bright
                if Double.random(in: 0...1) < 0.3 {
                    flickerOpacity = Double.random(in: 0.2...0.5)
                } else {
                    flickerOpacity = Double.random(in: 0.8...1.0)
                }
            }
        }
    }

    private func stopFlicker() {
        timer?.invalidate()
        timer = nil
        flickerOpacity = 1.0
    }
}

extension View {
    func neonFlicker(isActive: Bool, accentColor: Color) -> some View {
        modifier(NeonFlickerModifier(isActive: isActive, accentColor: accentColor))
    }
}

// MARK: - ChromaticAberrationText (DW-3.4)

// RGB split effect on text during warning phase.
// Three text layers: red offset left, blue offset right, base color centered.
// Uses .screen blend mode for additive color mixing on R/B channels.
// Small offset (1-2px) for subtle but visible chromatic split.
struct ChromaticAberrationText: View {
    let text: String
    let font: Font
    let baseColor: Color
    // Offset in points for R/B channels
    let offset: CGFloat

    var body: some View {
        ZStack {
            // Red channel -- offset left
            Text(text)
                .font(font)
                .foregroundColor(Color.red.opacity(0.6))
                .offset(x: -offset, y: 0)
                .blendMode(.screen)
            // Blue channel -- offset right
            Text(text)
                .font(font)
                .foregroundColor(Color.blue.opacity(0.6))
                .offset(x: offset, y: 0)
                .blendMode(.screen)
            // Base channel -- centered (main readable text)
            Text(text)
                .font(font)
                .foregroundColor(baseColor)
        }
    }
}

// MARK: - AnimationEffect Structs

// Registry entries for all Phase 3 effects.
// Lightweight structs conforming to AnimationEffect protocol.

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
