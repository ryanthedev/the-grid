import SwiftUI

// MARK: - Spacing Scale

// Same scale as NotificationPanelViews for visual consistency.
private enum DetailSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
}

// MARK: - Type Scale

private enum DetailTypeSize {
    static let title: CGFloat = 20
    static let body: CGFloat = 16
    static let meta: CGFloat = 12
}

// MARK: - Font Helper

// BerkeleyMono Nerd Font with system monospaced fallback.
private func berkeleyMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - DetailContentView

// Top-level SwiftUI view for the detail pop-out window.
// Switches between loading, loaded, and error states.
struct DetailContentView: View {
    @ObservedObject var viewModel: DetailViewModel

    var body: some View {
        VStack(spacing: 0) {
            DetailTitleBar(title: viewModel.title, theme: viewModel.theme)

            switch viewModel.state {
            case .idle:
                Spacer()
            case .loading:
                DetailLoadingView(theme: viewModel.theme)
            case .loaded(let messages):
                DetailMessageList(messages: messages, theme: viewModel.theme)
            case .error(let message):
                DetailErrorView(message: message, theme: viewModel.theme)
            }
        }
        .background(viewModel.theme.background)
    }
}

// MARK: - DetailTitleBar

struct DetailTitleBar: View {
    let title: String
    let theme: NotificationPanelTheme

    var body: some View {
        HStack {
            Text(title)
                .font(berkeleyMono(size: DetailTypeSize.title, weight: .bold))
                .foregroundColor(theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, DetailSpace.xl)
        .padding(.vertical, DetailSpace.lg)
        .background(theme.surface)
    }
}

// MARK: - DetailMessageList

// DW-3.2: Shows messages with sender direction and timestamps.
// Scrolls to the most recent message on appear.
struct DetailMessageList: View {
    let messages: [DetailMessage]
    let theme: NotificationPanelTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DetailSpace.md) {
                    ForEach(messages) { msg in
                        DetailMessageBubble(message: msg, theme: theme)
                            .id(msg.id)
                    }
                }
                .padding(DetailSpace.lg)
            }
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - DetailMessageBubble

// DW-3.2: Sender direction (you vs them) + relative timestamp.
// "you" messages align right, "them" messages align left.
struct DetailMessageBubble: View {
    let message: DetailMessage
    let theme: NotificationPanelTheme

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            // Sender + time header
            HStack(spacing: DetailSpace.xs) {
                if message.isFromMe {
                    Spacer()
                }
                Text(message.isFromMe ? "you" : "them")
                    .font(berkeleyMono(size: DetailTypeSize.meta))
                    .foregroundColor(theme.textTertiary)
                Text(message.relativeTime)
                    .font(berkeleyMono(size: DetailTypeSize.meta))
                    .foregroundColor(theme.textTertiary)
                if !message.isFromMe {
                    Spacer()
                }
            }

            // Message body
            Text(message.body)
                .font(berkeleyMono(size: DetailTypeSize.body))
                .foregroundColor(message.isFromMe ? theme.textSecondary : theme.textPrimary)
                .padding(.horizontal, DetailSpace.lg)
                .padding(.vertical, DetailSpace.md)
                .background(
                    message.isFromMe ? theme.surface : theme.surfaceSelected
                )
                .cornerRadius(DetailSpace.md)
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}

// MARK: - DetailLoadingView

struct DetailLoadingView: View {
    let theme: NotificationPanelTheme

    var body: some View {
        VStack {
            Text("Loading...")
                .font(berkeleyMono(size: DetailTypeSize.body))
                .foregroundColor(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DetailErrorView

struct DetailErrorView: View {
    let message: String
    let theme: NotificationPanelTheme

    var body: some View {
        VStack(spacing: DetailSpace.md) {
            Text("Error loading detail")
                .font(berkeleyMono(size: DetailTypeSize.body, weight: .bold))
                .foregroundColor(theme.urgent)
            Text(message)
                .font(berkeleyMono(size: DetailTypeSize.meta))
                .foregroundColor(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DetailSpace.xxl)
    }
}
