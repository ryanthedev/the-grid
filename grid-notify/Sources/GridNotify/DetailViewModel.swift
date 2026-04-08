import Foundation

// MARK: - DetailMessage

// A single message in a conversation detail view.
// Parsed from the JSON output of the detail command.
struct DetailMessage: Identifiable {
    let id = UUID()
    let body: String
    let isFromMe: Bool
    let relativeTime: String
}

// MARK: - RawDetailMessage

// Wire format from the detail command (e.g., imessage-watch.py --history).
// Maps to DetailMessage after computing relative timestamps.
private struct RawDetailMessage: Codable {
    let body: String
    let is_from_me: Bool
    let timestamp: Int
}

// MARK: - DetailError

enum DetailError: Error, LocalizedError {
    case invalidOutput
    case commandFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Invalid output from detail command"
        case .commandFailed(let status):
            return "Command exited with status \(status)"
        }
    }
}

// MARK: - DetailState

enum DetailState {
    case idle
    case loading
    case loaded(messages: [DetailMessage])
    case error(message: String)
}

// MARK: - DetailViewModel

// Manages the state for a detail pop-out window.
// Runs a shell command asynchronously, parses JSON output into messages,
// and publishes state changes for the SwiftUI view.
@MainActor
class DetailViewModel: ObservableObject {

    @Published var state: DetailState = .idle
    @Published var title: String = ""

    let theme: NotificationPanelTheme

    // Track in-flight task so we can cancel on re-load (DW-3.5)
    private var loadTask: Task<Void, Never>?

    init(theme: NotificationPanelTheme) {
        self.theme = theme
    }

    // Run the detail command and parse output.
    // Cancels any previous in-flight load (DW-3.5).
    func loadDetail(command: String, title: String) {
        self.title = title
        loadTask?.cancel()
        state = .loading

        loadTask = Task {
            do {
                let output = try await runShellCommand(command)
                guard !Task.isCancelled else { return }
                let messages = try parseDetailOutput(output)
                state = .loaded(messages: messages)
                jlog("notify.detail.loaded", data: [
                    "count": messages.count,
                    "title": title
                ])
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(message: error.localizedDescription)
                jlog("err.notify.detail.load", data: [
                    "err": "\(error)",
                    "cmd": command
                ])
            }
        }
    }

    // MARK: - Shell Execution

    // Run a shell command asynchronously and return stdout as a String.
    private func runShellCommand(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: DetailError.invalidOutput)
                        return
                    }

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: DetailError.commandFailed(
                            status: process.terminationStatus
                        ))
                        return
                    }

                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Parsing

    // Parse JSON array output from the detail command into DetailMessage array.
    private func parseDetailOutput(_ output: String) throws -> [DetailMessage] {
        guard let data = output.data(using: .utf8) else {
            throw DetailError.invalidOutput
        }

        let decoder = JSONDecoder()
        let rawMessages = try decoder.decode([RawDetailMessage].self, from: data)

        let now = Date()
        return rawMessages.map { raw in
            DetailMessage(
                body: raw.body,
                isFromMe: raw.is_from_me,
                relativeTime: formatRelativeTime(unix: raw.timestamp, now: now)
            )
        }
    }

    // Format a Unix timestamp as a relative time string.
    private func formatRelativeTime(unix: Int, now: Date) -> String {
        let messageDate = Date(timeIntervalSince1970: TimeInterval(unix))
        let interval = now.timeIntervalSince(messageDate)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
