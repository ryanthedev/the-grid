import SwiftUI

// MARK: - Spacing / Type Scale (mirrors NotificationAnimations)

private enum PTSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
}

private enum PTTypeSize {
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

// MARK: - HourglassSpriteView (DW-4.1)

// Cycles through braille animation frames based on TTL progress.
// Progress 0.0 = full TTL remaining, 1.0 = expired.
// Frame selection combines progress bias with timer-driven cycling
// to create a "draining sand" visual.
struct HourglassSpriteView: View {
    let progress: Double
    let color: Color

    // Braille patterns that suggest draining sand
    private static let sandFrames = [
        "\u{28FE}", "\u{28F7}", "\u{28EF}", "\u{28DF}",
        "\u{287F}", "\u{28BF}", "\u{28FB}", "\u{28FD}",
    ]

    @State private var animFrame: Int = 0
    @State private var timer: Timer?

    var body: some View {
        Text(Self.sandFrames[animFrame % Self.sandFrames.count])
            .font(berkeleyMono(size: PTTypeSize.body, weight: .bold))
            .foregroundColor(color)
            .onAppear {
                startAnimation()
            }
            .onDisappear {
                timer?.invalidate()
            }
    }

    private func startAnimation() {
        // Bias starting frame based on progress
        animFrame = Int(progress * Double(Self.sandFrames.count - 1))
        // ~4fps cycling
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            DispatchQueue.main.async {
                animFrame = (animFrame + 1) % Self.sandFrames.count
            }
        }
    }
}

// MARK: - PieCountdownView (DW-4.2)

// Shows a Unicode pie/circle character representing remaining time fraction.
// Progress 1.0 = full pie (plenty of time), 0.0 = empty (about to expire).
struct PieCountdownView: View {
    let progress: Double
    let color: Color

    // Circle fill characters from empty to full
    private static let pieFrames = [
        "\u{25CB}",
        "\u{25D4}",
        "\u{25D1}",
        "\u{25D5}",
        "\u{25CF}",
    ]

    var body: some View {
        let idx = Int(progress * Double(Self.pieFrames.count - 1))
        let clamped = max(0, min(Self.pieFrames.count - 1, idx))
        Text(Self.pieFrames[clamped])
            .font(berkeleyMono(size: PTTypeSize.meta, weight: .bold))
            .foregroundColor(color)
    }
}

// MARK: - HeartbeatModifier (DW-4.3)

// Scales the row up 2% then back down periodically.
// Creates a subtle pulse effect for unread notifications during idle phase.
// Uses a repeating spring animation for organic feel.
struct HeartbeatModifier: ViewModifier {
    let isActive: Bool

    @State private var beating: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && beating ? 1.02 : 1.0)
            .animation(
                isActive
                    ? .spring(response: 0.15, dampingFraction: 0.3)
                        .repeatForever(autoreverses: true)
                    : .default,
                value: beating
            )
            .onAppear {
                if isActive {
                    beating = true
                }
            }
            .onChange(of: isActive) { active in
                beating = active
            }
    }
}

extension View {
    func heartbeat(isActive: Bool) -> some View {
        modifier(HeartbeatModifier(isActive: isActive))
    }
}

// MARK: - DissolveModifier (DW-4.4)

// Removes individual characters randomly before dismiss.
// During ghost phase, increases opacity of random noise overlay
// as dissolveFraction approaches 1.0.
// dissolveFraction: 0.0 = fully visible, 1.0 = fully dissolved.
struct DissolveModifier: ViewModifier {
    let isActive: Bool
    let dissolveFraction: Double

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? max(0.1, 1.0 - dissolveFraction * 0.9) : 1.0)
            .overlay {
                if isActive && dissolveFraction > 0 {
                    GeometryReader { geo in
                        Canvas { context, size in
                            // Draw random black rectangles as "dissolved" holes
                            // Count increases with dissolveFraction
                            let holeCount = Int(dissolveFraction * 60)
                            for _ in 0..<holeCount {
                                let x = CGFloat.random(in: 0...size.width)
                                let y = CGFloat.random(in: 0...size.height)
                                let rect = CGRect(x: x, y: y, width: 4, height: 3)
                                context.fill(
                                    Path(rect),
                                    with: .color(.black.opacity(0.7))
                                )
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func dissolve(isActive: Bool, fraction: Double) -> some View {
        modifier(DissolveModifier(isActive: isActive, dissolveFraction: fraction))
    }
}

// MARK: - CursorBlinkText (DW-4.5)

// Shows blinking block cursor at end of unread notification titles.
// Terminal aesthetic: mimics a text terminal prompt cursor.
// Blink rate: 1Hz (toggle every 0.5s), standard terminal rate.
struct CursorBlinkText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var cursorVisible: Bool = true
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(font)
                .foregroundColor(color)
            // Block cursor character
            Text(cursorVisible ? "\u{2588}" : " ")
                .font(font)
                .foregroundColor(color.opacity(0.7))
        }
        .onAppear {
            startBlink()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startBlink() {
        // Toggle every 0.5s for 1Hz blink rate
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                cursorVisible.toggle()
            }
        }
    }
}

// MARK: - BootSequenceOverlay (DW-4.6)

// Plays a terminal boot sequence when the notification panel first appears.
// Not persisted across launches -- uses @State in the list view.
// Shows lines of terminal boot text one at a time, then fades out.
struct BootSequenceOverlay: View {
    @Binding var hasBooted: Bool
    let theme: NotificationPanelTheme

    @State private var visibleLines: Int = 0
    @State private var fadeOut: Bool = false
    @State private var timer: Timer?

    private static let bootLines = [
        "[grid-notify] v1.0.0",
        "loading notification engine...",
        "registering 32 animation effects...",
        "watching ~/.config/thegrid/notify.yaml",
        "ready.",
    ]

    var body: some View {
        if !hasBooted {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<visibleLines, id: \.self) { i in
                    HStack(spacing: PTSpace.xs) {
                        // Line number prefix
                        Text(">")
                            .font(berkeleyMono(size: PTTypeSize.meta))
                            .foregroundColor(theme.accent)
                        Text(Self.bootLines[i])
                            .font(berkeleyMono(size: PTTypeSize.meta))
                            .foregroundColor(
                                i == visibleLines - 1
                                    ? theme.accent : theme.textTertiary
                            )
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(PTSpace.md)
            .background(theme.background)
            .opacity(fadeOut ? 0 : 1)
            .onAppear {
                startBoot()
            }
            .onDisappear {
                timer?.invalidate()
            }
        }
    }

    private func startBoot() {
        // Show one line every 0.3s
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t in
            DispatchQueue.main.async {
                if visibleLines < Self.bootLines.count {
                    visibleLines += 1
                } else {
                    t.invalidate()
                    // Pause 0.5s then fade out
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            fadeOut = true
                        }
                        // Complete boot after fade
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            hasBooted = true
                        }
                    }
                }
            }
        }
    }
}

// MARK: - StackTraceText (DW-4.7)

// Formats warning phase text like a terminal error with line numbers.
// Shows "ERROR: <title>" header followed by body lines with line numbers.
struct StackTraceText: View {
    let title: String
    let bodyText: String
    let font: Font
    let theme: NotificationPanelTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Error header
            Text("ERROR: \(title)")
                .font(font.bold())
                .foregroundColor(theme.urgent)
                .lineLimit(1)
            // Body lines with line numbers
            ForEach(Array(bodyLines.enumerated()), id: \.offset) { idx, line in
                HStack(spacing: PTSpace.xs) {
                    Text(String(format: "%3d", idx + 1))
                        .font(berkeleyMono(size: PTTypeSize.meta))
                        .foregroundColor(theme.textTertiary)
                    Text("| \(line)")
                        .font(font)
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var bodyLines: [String] {
        if bodyText.isEmpty { return [] }
        let lines = bodyText.components(separatedBy: "\n")
        if lines.count > 1 {
            return lines
        }
        // Break long single line into ~40 char chunks
        guard bodyText.count > 40 else { return [bodyText] }
        var result: [String] = []
        var start = bodyText.startIndex
        while start < bodyText.endIndex {
            let end = bodyText.index(
                start,
                offsetBy: 40,
                limitedBy: bodyText.endIndex
            ) ?? bodyText.endIndex
            result.append(String(bodyText[start..<end]))
            start = end
        }
        return result
    }
}

// MARK: - ASCIIBorderModifier (DW-4.8)

// Draws box-drawing characters around the selected notification row.
// Uses Unicode: corners (top-left, top-right, bottom-left, bottom-right),
// horizontal bars, and vertical bars.
struct ASCIIBorderModifier: ViewModifier {
    let isActive: Bool
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        let charW = charWidth(geo.size.width)
                        let charH = charHeight(geo.size.height)

                        VStack(spacing: 0) {
                            // Top border: corner + horizontal bars + corner
                            topBorder(charW: charW)
                            // Middle: vertical bars framing content
                            Spacer(minLength: 0)
                            // Bottom border: corner + horizontal bars + corner
                            bottomBorder(charW: charW)
                        }
                        .overlay(alignment: .leading) {
                            // Left vertical bars
                            VStack(spacing: 0) {
                                ForEach(0..<charH, id: \.self) { _ in
                                    Text("\u{2502}")
                                        .font(berkeleyMono(size: PTTypeSize.meta))
                                        .foregroundColor(borderColor)
                                }
                            }
                            .padding(.vertical, PTTypeSize.meta)
                        }
                        .overlay(alignment: .trailing) {
                            // Right vertical bars
                            VStack(spacing: 0) {
                                ForEach(0..<charH, id: \.self) { _ in
                                    Text("\u{2502}")
                                        .font(berkeleyMono(size: PTTypeSize.meta))
                                        .foregroundColor(borderColor)
                                }
                            }
                            .padding(.vertical, PTTypeSize.meta)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private func topBorder(charW: Int) -> some View {
        HStack(spacing: 0) {
            Text("\u{250C}")
            Text(String(repeating: "\u{2500}", count: charW))
            Text("\u{2510}")
        }
        .font(berkeleyMono(size: PTTypeSize.meta))
        .foregroundColor(borderColor)
    }

    private func bottomBorder(charW: Int) -> some View {
        HStack(spacing: 0) {
            Text("\u{2514}")
            Text(String(repeating: "\u{2500}", count: charW))
            Text("\u{2518}")
        }
        .font(berkeleyMono(size: PTTypeSize.meta))
        .foregroundColor(borderColor)
    }

    // Approximate characters that fit in width
    private func charWidth(_ width: CGFloat) -> Int {
        max(1, Int(width / 7))
    }

    // Approximate lines that fit in height (minus top/bottom borders)
    private func charHeight(_ height: CGFloat) -> Int {
        max(1, Int((height - PTTypeSize.meta * 2) / PTTypeSize.meta))
    }
}

extension View {
    func asciiBorder(isActive: Bool, borderColor: Color) -> some View {
        modifier(ASCIIBorderModifier(isActive: isActive, borderColor: borderColor))
    }
}

// MARK: - AnimationEffect Structs

// Registry entries for all Phase 4 effects.
// Lightweight structs conforming to AnimationEffect protocol.

struct HourglassSpriteEffect: AnimationEffect {
    static let name = "hourglass_sprite"
}

struct PieCountdownEffect: AnimationEffect {
    static let name = "pie_countdown"
}

struct HeartbeatEffect: AnimationEffect {
    static let name = "heartbeat"
}

struct DissolveEffect: AnimationEffect {
    static let name = "dissolve"
}

struct CursorBlinkEffect: AnimationEffect {
    static let name = "cursor_blink"
}

struct BootSequenceEffect: AnimationEffect {
    static let name = "boot_sequence"
}

struct StackTraceEffect: AnimationEffect {
    static let name = "stack_trace"
}

struct ASCIIBorderEffect: AnimationEffect {
    static let name = "ascii_border"
}
