import SwiftUI

// MARK: - Spacing / Type Scale (mirrors NotificationPanelViews)

// Re-declared here to avoid cross-file private access issues.
// Values must stay in sync with NotificationPanelViews.swift.
private enum AnimSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
}

private enum AnimTypeSize {
    static let body: CGFloat = 16
    static let meta: CGFloat = 12
}

// MARK: - Font Helper (mirrors NotificationPanelViews)

private func berkeleyMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - TypewriterText

// Reveals text one character at a time over a specified duration.
// After the reveal completes, shows the full text statically.
struct TypewriterText: View {
    let text: String
    let font: Font
    let color: Color
    // Total time to reveal all characters
    let duration: TimeInterval

    @State private var visibleCount: Int = 0
    @State private var timer: Timer?

    var body: some View {
        // Show revealed characters plus transparent placeholders for the rest
        Text(revealedText)
            .font(font)
            .foregroundColor(color)
            .onAppear {
                startReveal()
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private var revealedText: String {
        if visibleCount >= text.count {
            return text
        }
        let idx = text.index(text.startIndex, offsetBy: visibleCount)
        return String(text[..<idx])
    }

    private func startReveal() {
        guard text.count > 0 else { return }
        let interval = duration / Double(text.count)
        visibleCount = 0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            DispatchQueue.main.async {
                if visibleCount < text.count {
                    visibleCount += 1
                } else {
                    t.invalidate()
                }
            }
        }
    }
}

// MARK: - MatrixText

// Characters start as random glyphs and resolve to the actual text.
// Each position independently "lands" on the correct character over ~0.8s.
struct MatrixText: View {
    let text: String
    let font: Font
    let color: Color
    // Total time for all characters to resolve
    let duration: TimeInterval

    // Pool of characters to scramble through
    private static let glyphPool = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz0123456789!@#$%&*")

    @State private var displayChars: [Character] = []
    @State private var resolved: [Bool] = []
    @State private var timer: Timer?

    var body: some View {
        Text(String(displayChars))
            .font(font)
            .foregroundColor(color)
            .onAppear {
                startResolve()
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startResolve() {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        displayChars = chars.map { _ in Self.glyphPool.randomElement() ?? "?" }
        resolved = Array(repeating: false, count: chars.count)

        // Resolve interval: each character gets a landing time
        let interval: TimeInterval = 0.03
        // Determine when each character resolves (staggered)
        let resolveIntervals = chars.indices.map { i in
            // Each character resolves at a random time within the duration
            Double.random(in: Double(i) / Double(chars.count) * duration ... duration)
        }
        let startTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { t in
            DispatchQueue.main.async {
                let elapsed = Date().timeIntervalSince(startTime)
                var allDone = true

                for i in chars.indices {
                    if resolved[i] { continue }
                    if elapsed >= resolveIntervals[i] {
                        displayChars[i] = chars[i]
                        resolved[i] = true
                    } else {
                        // Scramble unresolved positions
                        displayChars[i] = Self.glyphPool.randomElement() ?? "?"
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

// MARK: - MarqueeText

// Scrolls text horizontally when it overflows the available width.
// Pauses at start, scrolls to end, pauses, then resets.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    // Pixels per second scroll speed
    let speed: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isScrolling: Bool = false

    private var needsScroll: Bool {
        textWidth > containerWidth && containerWidth > 0
    }

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: needsScroll ? offset : 0)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.onAppear {
                            textWidth = textGeo.size.width
                            containerWidth = geo.size.width
                            startScrollCycle()
                        }
                    }
                )
        }
        .clipped()
    }

    private func startScrollCycle() {
        guard needsScroll else { return }
        let overflow = textWidth - containerWidth
        let scrollDuration = Double(overflow / speed)

        // Pause 1.5s, scroll, pause 1s, reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.linear(duration: scrollDuration)) {
                offset = -overflow
            }
            // After scroll completes, pause then reset
            DispatchQueue.main.asyncAfter(deadline: .now() + scrollDuration + 1.0) {
                offset = 0
                // Restart the cycle
                startScrollCycle()
            }
        }
    }
}

// MARK: - WaveText

// Characters ripple with subtle vertical offsets, creating a wave effect.
// Uses AttributedString with per-character baselineOffset to keep glyph
// shaping intact (the old per-Text approach broke kerning with custom fonts).
struct WaveText: View {
    let text: String
    let font: Font
    let color: Color
    let amplitude: CGFloat
    let cycleDuration: TimeInterval

    @State private var phase: Double = 0
    @State private var timer: Timer?

    var body: some View {
        Text(waveAttributedString)
            .font(font)
            .foregroundColor(color)
            .onAppear {
                startWave()
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private var waveAttributedString: AttributedString {
        var result = AttributedString()
        for (index, char) in text.enumerated() {
            var charAttr = AttributedString(String(char))
            let charPhase = phase + Double(index) * 0.4
            charAttr.baselineOffset = amplitude * CGFloat(sin(charPhase))
            result.append(charAttr)
        }
        return result
    }

    private func startWave() {
        let interval: TimeInterval = 1.0 / 30.0
        let phaseIncrement = (2.0 * .pi) / (cycleDuration / interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            DispatchQueue.main.async {
                phase += phaseIncrement
            }
        }
    }
}

// MARK: - ProgressBarView

// ASCII-style progress bar: [########..] that drains based on time remaining.
// Shows during warning phase only.
struct ProgressBarView: View {
    // Fraction remaining (0.0 to 1.0)
    let progress: Double
    let accentColor: Color
    let urgentColor: Color
    // Total width in character cells
    let barWidth: Int

    var body: some View {
        Text(barText)
            .font(berkeleyMono(size: AnimTypeSize.meta))
            .foregroundColor(progress > 0.3 ? accentColor : urgentColor)
    }

    private var barText: String {
        let filled = Int(Double(barWidth) * max(0, min(1, progress)))
        let empty = barWidth - filled
        // Use block characters for filled, light shade for empty
        let filledStr = String(repeating: "\u{2588}", count: filled)
        let emptyStr = String(repeating: "\u{2591}", count: empty)
        return "[\(filledStr)\(emptyStr)]"
    }
}

// MARK: - ShakeModifier

// Horizontal jitter during warning phase. Random offset that changes each tick.
struct ShakeModifier: ViewModifier {
    let isActive: Bool
    // Tick value from the view model, changes each second
    let tick: UInt

    func body(content: Content) -> some View {
        content
            .offset(x: isActive ? shakeOffset : 0)
    }

    private var shakeOffset: CGFloat {
        guard isActive else { return 0 }
        // Deterministic pseudo-random from tick
        var seed = tick
        seed = seed &* 2654435761
        seed = seed ^ (seed >> 16)
        let normalized = Double(seed % 1000) / 1000.0
        // Map to -2...+2
        return CGFloat(normalized * 4.0 - 2.0)
    }
}

extension View {
    func shake(isActive: Bool, tick: UInt) -> some View {
        modifier(ShakeModifier(isActive: isActive, tick: tick))
    }
}

// MARK: - BreathingModifier

// Subtle opacity pulse like a Mac sleep LED. 2s cycle, 0.3-1.0 range.
struct BreathingModifier: ViewModifier {
    let isActive: Bool

    @State private var opacity: Double = 0.3

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? opacity : 1.0)
            .onAppear {
                if isActive {
                    startBreathing()
                }
            }
            .onChange(of: isActive) { active in
                if active {
                    startBreathing()
                } else {
                    opacity = 1.0
                }
            }
    }

    private func startBreathing() {
        opacity = 0.3
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            opacity = 1.0
        }
    }
}

extension View {
    func breathing(isActive: Bool) -> some View {
        modifier(BreathingModifier(isActive: isActive))
    }
}

// MARK: - SlideInModifier

// Notification slides up from below with a spring animation on appear.
struct SlideInModifier: ViewModifier {
    let isActive: Bool

    @State private var appeared: Bool = false

    func body(content: Content) -> some View {
        content
            .offset(y: isActive && !appeared ? 30 : 0)
            .opacity(isActive && !appeared ? 0 : 1)
            .onAppear {
                if isActive {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        appeared = true
                    }
                } else {
                    appeared = true
                }
            }
    }
}

extension View {
    func slideIn(isActive: Bool) -> some View {
        modifier(SlideInModifier(isActive: isActive))
    }
}

// MARK: - GrowModifier

// Row padding increases during warning phase, making it physically taller.
struct GrowModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, isActive ? AnimSpace.md : 0)
            .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

extension View {
    func grow(isActive: Bool) -> some View {
        modifier(GrowModifier(isActive: isActive))
    }
}

// MARK: - InvertModifier

// Swaps foreground/background colors during warning phase.
// Applies a dark-on-light color scheme to the content.
struct InvertModifier: ViewModifier {
    let isActive: Bool
    let textColor: Color
    let backgroundColor: Color

    func body(content: Content) -> some View {
        content
            .background(isActive ? textColor : Color.clear)
            .colorMultiply(isActive ? backgroundColor : Color.white)
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

extension View {
    func invertColors(isActive: Bool, textColor: Color, backgroundColor: Color) -> some View {
        modifier(InvertModifier(isActive: isActive, textColor: textColor, backgroundColor: backgroundColor))
    }
}

// MARK: - BorderStrobeModifier

// Left edge bar alternates between urgent and accent colors rapidly.
struct BorderStrobeModifier: ViewModifier {
    let isActive: Bool
    let urgentColor: Color
    let accentColor: Color
    // Strobe interval in seconds
    let interval: TimeInterval

    @State private var strobeState: Bool = false
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(strobeState ? urgentColor : accentColor)
                        .frame(width: 3)
                }
            }
            .onAppear {
                if isActive {
                    startStrobe()
                }
            }
            .onChange(of: isActive) { active in
                if active {
                    startStrobe()
                } else {
                    timer?.invalidate()
                    timer = nil
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startStrobe() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            DispatchQueue.main.async {
                strobeState.toggle()
            }
        }
    }
}

extension View {
    func borderStrobe(
        isActive: Bool,
        urgentColor: Color,
        accentColor: Color,
        interval: TimeInterval = 0.2
    ) -> some View {
        modifier(BorderStrobeModifier(
            isActive: isActive,
            urgentColor: urgentColor,
            accentColor: accentColor,
            interval: interval
        ))
    }
}

// MARK: - FadeToGhostModifier

// In the last 3 seconds before expiry, opacity fades from 1.0 to 0.3.
struct FadeToGhostModifier: ViewModifier {
    // Seconds remaining until expiry
    let secondsRemaining: TimeInterval?
    // Fade starts at this many seconds before expiry
    let fadeStartSeconds: TimeInterval

    func body(content: Content) -> some View {
        content
            .opacity(ghostOpacity)
    }

    private var ghostOpacity: Double {
        guard let remaining = secondsRemaining else { return 1.0 }
        if remaining >= fadeStartSeconds { return 1.0 }
        if remaining <= 0 { return 0.3 }
        // Linear interpolation: fadeStartSeconds -> 1.0, 0 -> 0.3
        let fraction = remaining / fadeStartSeconds
        return 0.3 + (0.7 * fraction)
    }
}

extension View {
    func fadeToGhost(secondsRemaining: TimeInterval?, fadeStartSeconds: TimeInterval = 3.0) -> some View {
        modifier(FadeToGhostModifier(secondsRemaining: secondsRemaining, fadeStartSeconds: fadeStartSeconds))
    }
}
