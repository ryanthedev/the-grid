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

    var body: some View {
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
                            tick: viewModel.lifecycleTick
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

    // Seconds remaining for warning progress bar
    private var remaining: TimeInterval? {
        notification.secondsRemaining()
    }

    // Progress fraction for drain bar (1.0 = full, 0.0 = empty)
    private var warningProgress: Double {
        guard let r = remaining, notification.warnBefore > 0 else { return 0 }
        return r / notification.warnBefore
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
                        Text("\(Int(remaining))s")
                            .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
                            .foregroundColor(theme.urgent)
                    } else {
                        Text(relativeTime(notification.timestamp))
                            .font(berkeleyMono(size: TypeSize.meta))
                            .foregroundColor(theme.textTertiary)
                    }
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(berkeleyMono(size: TypeSize.body))
                        .foregroundColor(phase == .warning ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(2)
                }

                // Progress bar drain during warning phase
                if phase == .warning {
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
        .grow(isActive: phase == .warning)
        .background(backgroundColor)
        // Warning phase: pulsing urgent overlay
        .overlay(
            Rectangle()
                .fill(theme.urgent)
                .opacity(phase == .warning ? (warningPulse ? 0.15 : 0.05) : 0)
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
            isActive: phase == .warning,
            urgentColor: theme.urgent,
            accentColor: theme.accent
        )
        // Shake during warning phase
        .shake(isActive: phase == .warning, tick: tick)
        // Fade to ghost in last 3 seconds before expiry
        .fadeToGhost(secondsRemaining: remaining)
        // Slide in for new arrivals
        .slideIn(isActive: isArrival)
        .onAppear {
            // Flash if notification is less than 2 seconds old
            if isArrival {
                flashOpacity = 0.3
                withAnimation(.easeOut(duration: 0.8)) {
                    flashOpacity = 0
                }
            }
            // Start pulse if already in warning phase
            if phase == .warning {
                warningPulse = true
            }
        }
        .onChange(of: tick) { _ in
            // Start/stop pulse based on lifecycle phase
            if phase == .warning && !warningPulse {
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

    // Title view: adapts based on lifecycle phase
    // Arrival: matrix text (random chars resolve to real title)
    // Normal + unread: wave text (rippling character offsets)
    // Warning / read: static text
    @ViewBuilder
    private var titleView: some View {
        let titleColor = notification.isRead ? theme.textSecondary : theme.textPrimary
        if isArrival {
            MatrixText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor,
                duration: 0.8
            )
            .lineLimit(1)
        } else if !notification.isRead && phase == .normal {
            WaveText(
                text: displayTitle,
                font: berkeleyMono(size: TypeSize.body),
                color: titleColor,
                amplitude: 1.0,
                cycleDuration: 2.0
            )
            .lineLimit(1)
        } else {
            Text(displayTitle)
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(titleColor)
                .lineLimit(1)
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
    // Unread notifications get an animated braille spinner.
    @ViewBuilder
    private var priorityEdge: some View {
        let (color, symbol) = priorityVisuals(notification.priority)
        VStack(spacing: 2) {
            if phase == .warning {
                // Warning phase: fast urgent spinner
                SpriteView(
                    frames: Self.countdownFrames,
                    interval: 0.2,
                    color: theme.urgent
                )
            } else if !notification.isRead {
                SpriteView(
                    frames: Self.spinnerFrames,
                    interval: 0.1,
                    color: theme.accent
                )
                // Breathing pulse on the spinner like a Mac sleep LED
                .breathing(isActive: true)
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
