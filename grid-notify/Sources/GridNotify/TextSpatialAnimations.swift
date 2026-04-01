import SwiftUI

// MARK: - Spacing / Type Scale (mirrors NotificationAnimations)

private enum TSSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
}

private enum TSTypeSize {
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

// MARK: - GlitchText (DW-2.1)

// Randomly replaces characters with glitch glyphs on an interval.
// Unlike MatrixText which resolves to final text, glitch is ongoing while active.
// Terminal aesthetic: uses box-drawing and block element characters.
struct GlitchText: View {
    let text: String
    let font: Font
    let color: Color
    // Fraction of characters to glitch per tick (0.0-1.0)
    let intensity: Double

    // Pool of terminal-aesthetic glitch characters
    private static let glyphPool = Array("!@#$%^&*<>{}[]|/\\~`\u{2588}\u{2591}\u{2592}\u{2593}\u{2580}\u{2584}\u{258C}\u{2590}")

    @State private var displayChars: [Character] = []
    @State private var timer: Timer?

    var body: some View {
        Text(displayChars.isEmpty ? text : String(displayChars))
            .font(font)
            .foregroundColor(color)
            .onAppear {
                startGlitch()
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startGlitch() {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        displayChars = chars

        // ~12fps glitch rate
        let interval: TimeInterval = 0.08
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            DispatchQueue.main.async {
                var updated = chars
                for i in chars.indices {
                    if Double.random(in: 0...1) < intensity {
                        updated[i] = Self.glyphPool.randomElement() ?? "?"
                    }
                }
                displayChars = updated
            }
        }
    }
}

// MARK: - RedactText (DW-2.2)

// Text starts as full block characters, then reveals char by char over duration.
// Each character independently "unredacts" at a staggered random time.
struct RedactText: View {
    let text: String
    let font: Font
    let color: Color
    // Total time to reveal all characters
    let duration: TimeInterval

    @State private var displayChars: [Character] = []
    @State private var revealed: [Bool] = []
    @State private var timer: Timer?

    var body: some View {
        Text(displayChars.isEmpty ? text : String(displayChars))
            .font(font)
            .foregroundColor(color)
            .onAppear {
                startReveal()
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startReveal() {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        // Start all as full block character
        displayChars = Array(repeating: Character("\u{2588}"), count: chars.count)
        revealed = Array(repeating: false, count: chars.count)

        // Each character reveals at a staggered random time within duration
        let revealTimes = chars.indices.map { i in
            Double.random(
                in: Double(i) / Double(chars.count) * duration ... duration
            )
        }
        let startTime = Date()

        // ~25fps update rate
        let interval: TimeInterval = 0.04
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            DispatchQueue.main.async {
                let elapsed = Date().timeIntervalSince(startTime)
                var allDone = true

                for i in chars.indices {
                    if revealed[i] { continue }
                    if elapsed >= revealTimes[i] {
                        displayChars[i] = chars[i]
                        revealed[i] = true
                    } else {
                        allDone = false
                    }
                }

                if allDone {
                    t.invalidate()
                }
            }
        }
    }
}

// MARK: - TypingIndicatorText (DW-2.3)

// Shows animated "..." dots that cycle, then transitions to real text.
// The dots phase lasts ~1.5s, then content fades in.
struct TypingIndicatorText: View {
    let text: String
    let font: Font
    let color: Color
    let theme: NotificationPanelTheme

    @State private var showText: Bool = false
    @State private var dotCount: Int = 1
    @State private var dotTimer: Timer?

    var body: some View {
        if showText {
            Text(text)
                .font(font)
                .foregroundColor(color)
        } else {
            Text(String(repeating: ".", count: dotCount))
                .font(font)
                .foregroundColor(theme.textTertiary)
                .onAppear {
                    startDots()
                }
                .onDisappear {
                    dotTimer?.invalidate()
                }
        }
    }

    private func startDots() {
        // Cycle dots 1..3 repeatedly
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            DispatchQueue.main.async {
                dotCount = (dotCount % 3) + 1
            }
        }

        // After 1.5s, show real content
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dotTimer?.invalidate()
            dotTimer = nil
            withAnimation(.easeIn(duration: 0.2)) {
                showText = true
            }
        }
    }
}

// MARK: - ScanlineModifier (DW-2.4)

// Horizontal bright line sweeps top-to-bottom across the notification row.
// A thin gradient rectangle overlay that moves vertically on a timer.
struct ScanlineModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color

    @State private var progress: CGFloat = 0
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        accentColor.opacity(0.15),
                                        accentColor.opacity(0.3),
                                        accentColor.opacity(0.15),
                                        .clear,
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 3)
                            .offset(y: progress * geo.size.height)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                if isActive {
                    startScanline()
                }
            }
            .onChange(of: isActive) { active in
                if active {
                    startScanline()
                } else {
                    stopScanline()
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startScanline() {
        progress = 0
        // ~30fps, 2s full sweep
        let interval: TimeInterval = 1.0 / 30.0
        let increment: CGFloat = CGFloat(interval / 2.0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            DispatchQueue.main.async {
                progress += increment
                // Loop back to top
                if progress > 1.0 {
                    progress = 0
                }
            }
        }
    }

    private func stopScanline() {
        timer?.invalidate()
        timer = nil
    }
}

extension View {
    func scanline(isActive: Bool, accentColor: Color) -> some View {
        modifier(ScanlineModifier(isActive: isActive, accentColor: accentColor))
    }
}

// MARK: - BounceModifier (DW-2.5)

// Spring bounce on arrival. Starts scaled down, bounces to full size.
// Uses spring animation with low damping for visible bounce.
struct BounceModifier: ViewModifier {
    let isActive: Bool

    @State private var scale: CGFloat = 0.8

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && scale < 1.0 ? scale : 1.0)
            .onAppear {
                if isActive {
                    scale = 0.8
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                        scale = 1.0
                    }
                }
            }
    }
}

extension View {
    func bounce(isActive: Bool) -> some View {
        modifier(BounceModifier(isActive: isActive))
    }
}

// MARK: - AccordionModifier (DW-2.6)

// Expands row from zero height to full height on arrival.
// Uses scaleEffect on Y axis with clipping.
struct AccordionModifier: ViewModifier {
    let isActive: Bool

    @State private var expanded: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                y: isActive && !expanded ? 0.01 : 1.0,
                anchor: .top
            )
            .clipped()
            .opacity(isActive && !expanded ? 0 : 1)
            .onAppear {
                if isActive {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                        expanded = true
                    }
                } else {
                    expanded = true
                }
            }
    }
}

extension View {
    func accordion(isActive: Bool) -> some View {
        modifier(AccordionModifier(isActive: isActive))
    }
}

// MARK: - TiltModifier (DW-2.7)

// Subtle 3D rotation when selected. Tilts slightly on X axis.
// Animates in when selected, back to flat when deselected.
struct TiltModifier: ViewModifier {
    let isActive: Bool

    // Small tilt angle in degrees
    private let tiltDegrees: Double = 2.0

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(isActive ? tiltDegrees : 0),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.5
            )
            .animation(.easeInOut(duration: 0.25), value: isActive)
    }
}

extension View {
    func tilt(isActive: Bool) -> some View {
        modifier(TiltModifier(isActive: isActive))
    }
}

// MARK: - ParallaxModifier (DW-2.8)

// Title and body move at different vertical offsets based on tick.
// Creates subtle depth illusion. Title (layer 0) moves more than body (layer 1).
// Uses sin(tick) for smooth oscillation.
struct ParallaxModifier: ViewModifier {
    let isActive: Bool
    let tick: UInt
    // Layer index: 0 = title (larger amplitude), 1 = body (smaller amplitude)
    let layer: Int

    // Amplitude per layer in points
    private static let amplitudes: [CGFloat] = [1.5, 0.5]

    func body(content: Content) -> some View {
        let amplitude = layer < Self.amplitudes.count ? Self.amplitudes[layer] : 0
        content
            .offset(
                y: isActive ? amplitude * CGFloat(sin(Double(tick) * 0.3)) : 0
            )
    }
}

extension View {
    func parallax(isActive: Bool, tick: UInt, layer: Int) -> some View {
        modifier(ParallaxModifier(isActive: isActive, tick: tick, layer: layer))
    }
}

// MARK: - AnimationEffect Structs

// Registry entries for all Phase 2 effects.
// Lightweight structs conforming to AnimationEffect protocol.

struct GlitchEffect: AnimationEffect {
    static let name = "glitch"
}

struct RedactEffect: AnimationEffect {
    static let name = "redact"
}

struct TypingIndicatorEffect: AnimationEffect {
    static let name = "typing_indicator"
}

struct ScanlineEffect: AnimationEffect {
    static let name = "scanline"
}

struct BounceEffect: AnimationEffect {
    static let name = "bounce"
}

struct AccordionEffect: AnimationEffect {
    static let name = "accordion"
}

struct TiltEffect: AnimationEffect {
    static let name = "tilt"
}

struct ParallaxEffect: AnimationEffect {
    static let name = "parallax"
}
