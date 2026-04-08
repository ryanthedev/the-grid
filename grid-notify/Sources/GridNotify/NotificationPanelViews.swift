import SwiftUI

// MARK: - Spacing Scale

// Base unit 4px, x1.5 progression: 4, 6, 8, 12, 16, 24
private enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
}

// MARK: - Type Scale

// Bumped sizes for readability in a skinny panel
private enum TypeSize {
    static let title: CGFloat = 20
    static let body: CGFloat = 16
    static let meta: CGFloat = 12
}

// MARK: - Main Content View

struct NotificationPanelContentView: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.mode == .filter {
                NotificationFilterBar(viewModel: viewModel)
            }

            if viewModel.mode == .help {
                NotificationHelpView(theme: viewModel.theme)
            } else if viewModel.notifications.isEmpty {
                NotificationEmptyView(theme: viewModel.theme)
            } else {
                NotificationListView(viewModel: viewModel)
            }

            NotificationStatusBar(viewModel: viewModel)
        }
        .background(viewModel.theme.background)
        .onAppear {
            viewModel.refreshNotifications()
        }
    }
}

// MARK: - Header View

struct NotificationHeaderView: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack {
            Text("Notifications")
                .font(berkeleyMono(size: TypeSize.title, weight: .bold))
                .foregroundColor(viewModel.theme.textPrimary)

            Spacer()

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
                    .foregroundColor(viewModel.theme.background)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(viewModel.theme.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .background(viewModel.theme.surface)
    }

    private var unreadCount: Int {
        viewModel.notifications.filter { !$0.isRead }.count
    }
}

// MARK: - Filter Bar

struct NotificationFilterBar: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack(spacing: Space.md) {
            Text("/")
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(viewModel.theme.accent)

            TextField("filter...", text: filterTextBinding)
                .textFieldStyle(.plain)
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(viewModel.theme.textPrimary)
                .onSubmit {
                    viewModel.exitFilterMode()
                }
                .onExitCommand {
                    viewModel.clearFilter()
                    viewModel.exitFilterMode()
                }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(viewModel.theme.filterBackground)
    }

    private var filterTextBinding: Binding<String> {
        Binding(
            get: { viewModel.filterText },
            set: { viewModel.updateFilter($0) }
        )
    }
}

// MARK: - Notification List

struct NotificationListView: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    // Boot sequence plays once per session (not persisted across launches)
    @State private var hasBooted: Bool = false

    var body: some View {
        ZStack {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(viewModel.notifications.enumerated()),
                        id: \.element.id
                    ) { index, notification in
                        NotificationItemView(
                            notification: notification,
                            isSelected: index == viewModel.selectedIndex,
                            isVisualSelected: viewModel.visualSelectedRange?.contains(index) ?? false,
                            theme: viewModel.theme,
                            tick: viewModel.lifecycleTick,
                            animationConfig: viewModel.animationConfig
                        )
                        .id(notification.id)
                        // Flip each item back right-side up
                        .scaleEffect(x: 1, y: -1, anchor: .center)
                    }
                }
            }
            // Flip the entire scroll view — content now grows from bottom
            .scaleEffect(x: 1, y: -1, anchor: .center)
            .onChange(of: viewModel.selectedIndex) { _ in
                if let notification = viewModel.currentNotification {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(notification.id, anchor: .center)
                    }
                }
            }
            // Auto-scroll to newest when notification count changes
            .onChange(of: viewModel.notifications.count) { _ in
                if let first = viewModel.notifications.first {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }

        // Boot sequence overlay (plays once per session)
        if !hasBooted {
            BootSequenceOverlay(
                hasBooted: $hasBooted,
                theme: viewModel.theme
            )
        }
        }
    }
}

// MARK: - Animated Sprite

// Cycles through Unicode braille frames for unread notifications.
// Stops animating once the notification is read.
struct SpriteView: View {
    let frames: [String]
    let interval: TimeInterval
    let color: Color

    @State private var frameIndex = 0

    var body: some View {
        Text(frames[frameIndex])
            .font(berkeleyMono(size: TypeSize.title, weight: .bold))
            .foregroundColor(color)
            .onAppear {
                startAnimation()
            }
    }

    private func startAnimation() {
        guard frames.count > 1 else { return }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            DispatchQueue.main.async {
                frameIndex = (frameIndex + 1) % frames.count
            }
        }
    }
}

// MARK: - Single Notification Item

struct NotificationItemView: View {
    let notification: GridNotification
    let isSelected: Bool
    let isVisualSelected: Bool
    let theme: NotificationPanelTheme
    // Lifecycle tick from ViewModel — triggers re-render for warning phase
    let tick: UInt
    // Animation config — drives which animations are active per phase
    let animationConfig: AnimationConfig

    // Flash state for new notifications
    @State private var flashOpacity: Double = 0
    // Warning phase pulse
    @State private var warningPulse: Bool = false

    // Braille spinner frames
    private static let spinnerFrames = [
        "\u{28FE}", "\u{28FD}", "\u{28FB}", "\u{28BF}",
        "\u{287F}", "\u{28DF}", "\u{28EF}", "\u{28F7}"
    ]

    // Warning phase countdown frames
    private static let countdownFrames = [
        "\u{25F7}", "\u{25F6}", "\u{25F5}", "\u{25F4}"
    ]

    private var phase: GridNotification.LifecyclePhase {
        notification.lifecyclePhase()
    }

    // Whether the notification arrived within the last 2 seconds
    private var isArrival: Bool {
        Date().timeIntervalSince(notification.timestamp) < 2
    }

    // Computed animation phase (replaces scattered conditionals)
    private var animPhase: AnimationPhase {
        computeAnimationPhase(notification: notification, isArrival: isArrival)
    }

    // Notification age in seconds (for heatmap)
    private var notificationAge: TimeInterval {
        Date().timeIntervalSince(notification.timestamp)
    }

    // Seconds remaining for warning progress bar
    private var remaining: TimeInterval? {
        notification.secondsRemaining()
    }

    // Progress fraction for drain bar (1.0 = full, 0.0 = empty)
    private var warningProgress: Double {
        guard let r = remaining, notification.warnBefore > 0 else { return 0 }
        return r / notification.warnBefore
    }

    // Check if a named animation is active for the current phase
    private func isActive(_ name: String) -> Bool {
        isAnimationActive(
            name,
            config: animationConfig,
            notification: notification,
            animationPhase: animPhase
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            // Priority: 2px left-edge bar (full item height) + symbol/sprite
            priorityEdge

            VStack(alignment: .leading, spacing: Space.xs) {
                // Title row
                HStack(spacing: Space.xs) {
                    if notification.isPinned {
                        Text("+")
                            .font(berkeleyMono(size: TypeSize.body, weight: .bold))
                            .foregroundColor(theme.pinned)
                    }

                    titleView

                    Spacer()

                    // Show countdown during warning phase, relative time otherwise
                    if phase == .warning, let remaining = notification.secondsRemaining() {
                        if isActive("pie_countdown") {
                            PieCountdownView(
                                progress: remaining / notification.warnBefore,
                                color: theme.urgent
                            )
                        }
                        Text("\(Int(remaining))s")
                            .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
                            .foregroundColor(theme.urgent)
                    } else {
                        Text(relativeTime(notification.timestamp))
                            .font(berkeleyMono(size: TypeSize.meta))
                            .foregroundColor(theme.textTertiary)
                    }
                }

                if isActive("stack_trace") && phase == .warning && !notification.body.isEmpty {
                    StackTraceText(
                        title: notification.title,
                        bodyText: notification.body,
                        font: berkeleyMono(size: TypeSize.meta),
                        theme: theme
                    )
                } else if !notification.body.isEmpty {
                    let bodyColor = (isActive("warning_pulse") && phase == .warning)
                        ? theme.textPrimary : theme.textSecondary
                    if isActive("typing_indicator") && isArrival {
                        TypingIndicatorText(
                            text: notification.body,
                            font: berkeleyMono(size: TypeSize.body),
                            color: bodyColor,
                            theme: theme
                        )
                        .lineLimit(2)
                        .parallax(isActive: isActive("parallax"), tick: tick, layer: 1)
                    } else {
                        Text(notification.body)
                            .font(berkeleyMono(size: TypeSize.body))
                            .foregroundColor(bodyColor)
                            .lineLimit(2)
                            .parallax(isActive: isActive("parallax"), tick: tick, layer: 1)
                    }
                }

                // Progress bar drain during warning phase
                if isActive("progress_bar") && phase == .warning {
                    ProgressBarView(
                        progress: warningProgress,
                        accentColor: theme.accent,
                        urgentColor: theme.urgent,
                        barWidth: 20
                    )
                }
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, Space.lg)
        .padding(.vertical, Space.md)
        // Grow: extra vertical padding during warning phase
        .grow(isActive: isActive("grow") && phase == .warning)
        .background(backgroundColor)
        // Warning phase: pulsing urgent overlay
        .overlay(
            Rectangle()
                .fill(theme.urgent)
                .opacity(isActive("warning_pulse") && phase == .warning ? (warningPulse ? 0.15 : 0.05) : 0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: warningPulse)
        )
        // Flash overlay for new notifications
        .overlay(
            Rectangle()
                .fill(theme.accent)
                .opacity(flashOpacity)
        )
        // Border strobe during warning phase
        .borderStrobe(
            isActive: isActive("border_strobe") && phase == .warning,
            urgentColor: theme.urgent,
            accentColor: theme.accent
        )
        // Shake during warning phase
        .shake(isActive: isActive("shake") && phase == .warning, tick: tick)
        // Fade to ghost in last seconds before expiry
        .fadeToGhost(secondsRemaining: isActive("fade_to_ghost") ? remaining : nil)
        // Slide in for new arrivals
        .slideIn(isActive: isActive("slide_in") && isArrival)
        // Phase 2: spatial animations
        // Bounce on arrival
        .bounce(isActive: isActive("bounce") && isArrival)
        // Accordion expand on arrival
        .accordion(isActive: isActive("accordion") && isArrival)
        // Tilt on selection
        .tilt(isActive: isActive("tilt") && isSelected)
        // Scanline sweep
        .scanline(isActive: isActive("scanline"), accentColor: theme.accent)
        // Phase 3: color + mood animations
        // Gradient sweep on arrival
        .gradientSweep(isActive: isActive("gradient_sweep") && isArrival, accentColor: theme.accent)
        // Heatmap age-based background tint
        .heatmap(isActive: isActive("heatmap"), age: notificationAge, warmColor: theme.urgent)
        // Neon flicker for urgent notifications
        .neonFlicker(isActive: isActive("neon_flicker") && notification.priority == .urgent, accentColor: theme.accent)
        // Phase 4: progress + terminal animations
        // Heartbeat pulse for unread notifications in idle phase
        .heartbeat(isActive: isActive("heartbeat") && !notification.isRead && animPhase == .idle)
        // Dissolve: random noise overlay before dismiss in ghost phase
        .dissolve(
            isActive: isActive("dissolve") && animPhase == .ghost,
            fraction: {
                guard let r = remaining, r < 3.0 else { return 0 }
                return 1.0 - (r / 3.0)
            }()
        )
        // ASCII border around selected notification
        .asciiBorder(isActive: isActive("ascii_border") && isSelected, borderColor: theme.accent)
        .onAppear {
            // Flash if notification is less than 2 seconds old
            if isArrival && isActive("arrival_flash") {
                flashOpacity = 0.3
                withAnimation(.easeOut(duration: 0.8)) {
                    flashOpacity = 0
                }
            }
            // Start pulse if already in warning phase
            if phase == .warning && isActive("warning_pulse") {
                warningPulse = true
            }
        }
        .onChange(of: tick) { _ in
            // Start/stop pulse based on lifecycle phase
            if phase == .warning && isActive("warning_pulse") && !warningPulse {
                warningPulse = true
            }
        }
    }

    // Display title with group count suffix when > 1 (e.g., "Sarah (3)")
    private var displayTitle: String {
        if notification.groupCount > 1 {
            return "\(notification.title) (\(notification.groupCount))"
        }
        return notification.title
    }

    // Title view: adapts based on animation config.
    // Priority: redact > matrix_title on arrival, glitch on warning,
    // wave_title for unread, static otherwise.
    @ViewBuilder
    private var titleView: some View {
        let titleColor = notification.isRead ? theme.textSecondary : theme.textPrimary
        if isActive("redact") && isArrival {
            RedactText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor,
                duration: 1.0
            )
            .lineLimit(1)
            .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        } else if isActive("glitch") && phase == .warning {
            GlitchText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor,
                intensity: 0.15
            )
            .lineLimit(1)
            .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        } else if isActive("chromatic_aberration") && phase == .warning {
            ChromaticAberrationText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                baseColor: titleColor,
                offset: 1.5
            )
            .lineLimit(1)
            .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        } else if isActive("matrix_title") && isArrival {
            MatrixText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor,
                duration: 0.8
            )
            .lineLimit(1)
            .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        } else if isActive("wave_title") && !notification.isRead {
            WaveText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor,
                amplitude: 1.0,
                cycleDuration: 2.0
            )
            .lineLimit(1)
            .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        } else if isActive("cursor_blink") && !notification.isRead {
            CursorBlinkText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor
            )
            .lineLimit(1)
            .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        } else {
            Text(displayTitle)
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(titleColor)
                .lineLimit(1)
                .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.surfaceSelected
        }
        if isVisualSelected {
            return theme.surface
        }
        return Color.clear
    }

    // Left-edge colored bar: 2px wide, full item height.
    // Spinner animations controlled by config.
    @ViewBuilder
    private var priorityEdge: some View {
        let (color, symbol) = priorityVisuals(notification.priority)
        VStack(spacing: 2) {
            if isActive("hourglass_sprite") && notification.ttl > 0,
               let r = remaining
            {
                // Hourglass sprite cycles frames based on TTL progress
                let progress = 1.0 - (r / notification.ttl)
                HourglassSpriteView(
                    progress: progress,
                    color: theme.accent
                )
            } else if isActive("spinner") && phase == .warning {
                // Warning phase: fast urgent spinner
                SpriteView(
                    frames: Self.countdownFrames,
                    interval: 0.2,
                    color: theme.urgent
                )
            } else if isActive("spinner") && !notification.isRead {
                SpriteView(
                    frames: Self.spinnerFrames,
                    interval: 0.1,
                    color: theme.accent
                )
                // Breathing pulse on the spinner like a Mac sleep LED
                .breathing(isActive: isActive("breathing"))
            } else {
                Text(symbol)
                    .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
                    .foregroundColor(color)
            }
        }
        .frame(width: Space.xl)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            // Left bar: urgent color during warning, priority color otherwise
            Rectangle()
                .fill(phase == .warning ? theme.urgent : color)
                .frame(width: phase == .warning ? 3 : 2)
                .opacity(phase == .warning || notification.priority >= .high ? 1.0 : 0.0)
        }
    }

    private func priorityVisuals(_ priority: GridNotificationPriority) -> (Color, String) {
        switch priority {
        case .urgent: return (theme.urgent, "!")
        case .high:   return (theme.accent, "^")
        case .normal: return (.clear, " ")
        case .low:    return (theme.textTertiary, "\u{00B7}")
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - Empty State

struct NotificationEmptyView: View {
    let theme: NotificationPanelTheme

    var body: some View {
        VStack(spacing: Space.md) {
            Text("No notifications")
                .font(berkeleyMono(size: TypeSize.title))
                .foregroundColor(theme.textTertiary)
            Text("Notifications from pipe and file watchers appear here")
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
    }
}

// MARK: - Help View

struct NotificationHelpView: View {
    let theme: NotificationPanelTheme

    // Keybinding entries: (key, description)
    private let bindings: [(String, String)] = [
        ("j / k", "Navigate down / up"),
        ("g / G", "Jump to oldest / newest"),
        ("d / x", "Dismiss selected"),
        ("p", "Toggle pin"),
        ("s", "Snooze (5 min)"),
        ("+ / -", "Increase / decrease priority"),
        ("Return", "Execute action"),
        ("/", "Filter mode"),
        ("V", "Visual select mode"),
        ("?", "Toggle this help"),
        ("Esc", "Exit current mode"),
    ]

    private let visualBindings: [(String, String)] = [
        ("j / k", "Extend selection"),
        ("d", "Bulk dismiss"),
        ("p", "Bulk pin"),
        ("Esc", "Exit visual mode"),
    ]

    private let textAnimations: [(String, String)] = [
        ("matrix_title", "Characters resolve from random glyphs"),
        ("wave_title", "Wavy motion (unread only)"),
        ("glitch", "Random character corruption"),
        ("redact", "Text reveals from block characters"),
        ("typing_indicator", "Character-by-character reveal"),
        ("cursor_blink", "Blinking cursor at end"),
        ("chromatic_aberration", "RGB color split effect"),
    ]

    private let spatialAnimations: [(String, String)] = [
        ("slide_in", "Slides in from top"),
        ("bounce", "Elastic bounce on arrival"),
        ("accordion", "Expands from zero height"),
        ("tilt", "3D rotation on selection"),
        ("parallax", "Depth scroll effect"),
        ("scanline", "Horizontal sweep"),
    ]

    private let colorAnimations: [(String, String)] = [
        ("gradient_sweep", "Accent color wash"),
        ("heatmap", "Background tint by age"),
        ("neon_flicker", "Border flicker effect"),
    ]

    private let progressAnimations: [(String, String)] = [
        ("hourglass_sprite", "Sprite frames by progress"),
        ("pie_countdown", "Shrinking pie chart"),
        ("heartbeat", "Scale pulse for unread"),
        ("progress_bar", "Drain bar during warning"),
    ]

    private let terminalAnimations: [(String, String)] = [
        ("shake", "Horizontal shake"),
        ("grow", "Extra vertical padding"),
        ("warning_pulse", "Pulsing urgent overlay"),
        ("border_strobe", "Border strobe effect"),
        ("spinner", "Animated spinner"),
        ("breathing", "Breathing pulse on spinner"),
        ("fade_to_ghost", "Fades in last 3 seconds"),
        ("dissolve", "Random character noise"),
        ("ascii_border", "Box-drawing border"),
        ("boot_sequence", "Terminal boot animation"),
        ("stack_trace", "Error format with line numbers"),
        ("arrival_flash", "Accent flash on arrival"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: Space.sm) {
                    sectionHeader("Normal Mode")
                    ForEach(bindings, id: \.0) { key, desc in
                        bindingRow(key: key, desc: desc)
                    }

                    Divider()
                        .background(theme.border)
                        .padding(.vertical, Space.sm)

                    sectionHeader("Visual Select")
                    ForEach(visualBindings, id: \.0) { key, desc in
                        bindingRow(key: key, desc: desc)
                    }

                    Divider()
                        .background(theme.border)
                        .padding(.vertical, Space.sm)

                    sectionHeader("Animations")

                    sectionSubheader("Text")
                    ForEach(textAnimations, id: \.0) { name, desc in
                        animationRow(name: name, desc: desc)
                    }

                    sectionSubheader("Spatial")
                    ForEach(spatialAnimations, id: \.0) { name, desc in
                        animationRow(name: name, desc: desc)
                    }

                    sectionSubheader("Color")
                    ForEach(colorAnimations, id: \.0) { name, desc in
                        animationRow(name: name, desc: desc)
                    }

                    sectionSubheader("Progress")
                    ForEach(progressAnimations, id: \.0) { name, desc in
                        animationRow(name: name, desc: desc)
                    }

                    sectionSubheader("Terminal & Lifecycle")
                    ForEach(terminalAnimations, id: \.0) { name, desc in
                        animationRow(name: name, desc: desc)
                    }
                }
                .padding(Space.lg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(berkeleyMono(size: TypeSize.body, weight: .bold))
            .foregroundColor(theme.accent)
            .padding(.bottom, Space.xs)
    }

    private func sectionSubheader(_ title: String) -> some View {
        Text(title)
            .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
            .foregroundColor(theme.textSecondary)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xs)
    }

    private func bindingRow(key: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(key)
                .font(berkeleyMono(size: TypeSize.body, weight: .medium))
                .foregroundColor(theme.textPrimary)
                .frame(width: 80, alignment: .trailing)
            Text(desc)
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(theme.textSecondary)
            Spacer()
        }
    }

    private func animationRow(name: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(name)
                .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 100, alignment: .trailing)
            Text(desc)
                .font(berkeleyMono(size: TypeSize.meta))
                .foregroundColor(theme.textSecondary)
            Spacer()
        }
    }
}

// MARK: - Status Bar

struct NotificationStatusBar: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack {
            Text(viewModel.statusText)
                .font(berkeleyMono(size: TypeSize.meta))
                .foregroundColor(viewModel.theme.textTertiary)
                .lineLimit(1)

            Spacer()

            // Mode indicator -- accent color only when mode is active
            switch viewModel.mode {
            case .normal:
                Text("NORMAL")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.textTertiary)
            case .filter:
                Text("FILTER")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.accent)
            case .visualSelect:
                Text("VISUAL")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.accent)
            case .help:
                Text("HELP")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.accent)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.sm)
        .background(viewModel.theme.surface)
    }
}

// MARK: - Font Helper

// BerkeleyMono Nerd Font with system monospaced fallback.
// Used for ALL text in the panel -- no mixing.
private func berkeleyMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}
