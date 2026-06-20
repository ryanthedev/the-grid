import AppKit
import Foundation

// MARK: - TmuxStatusKind

// Status classification for a tmux window.
// Exactly one of these five values appears in the status file.
// Unknown strings from external input decode to .idle (lenient decode).
enum TmuxStatusKind: String, Codable {
    case active
    case running
    case waiting
    case idle
    case error

    // Single-character glyph for compact UI display.
    var glyph: String {
        switch self {
        case .active: return "●"
        case .running: return "▶"
        case .waiting: return "⏸"
        case .idle: return "○"
        case .error: return "✕"
        }
    }

    // Color for glyph and status indicator in the dashboard.
    var color: NSColor {
        switch self {
        case .active: return NSColor.systemGreen
        case .running: return NSColor.systemBlue
        case .waiting: return NSColor.systemYellow
        case .idle: return NSColor.secondaryLabelColor
        case .error: return NSColor.systemRed
        }
    }

    // Lenient decode: unknown statusKind strings map to .idle rather than throwing.
    // The status file is external input; new kinds added in future skill versions
    // should degrade gracefully rather than break the decoder.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TmuxStatusKind(rawValue: raw) ?? .idle
    }
}

// MARK: - TmuxWindow

// A single tmux window within a session.
struct TmuxWindow: Decodable {
    // 0-based window index within the session.
    let index: Int
    // Window name as reported by tmux.
    let name: String
    // Foreground command running in the active pane.
    let command: String
    // Whether this is the session's currently active window.
    let active: Bool
    // AI-assigned status classification.
    let statusKind: TmuxStatusKind
    // One-line AI summary of what is happening in this window.
    // Capped during rendering — never trust this length for layout.
    let summary: String
    // tmux target string in "session:index" form (e.g. "work:0").
    let target: String

    // Maximum characters to trust from the summary field.
    // Longer summaries are truncated at display time (not at decode).
    static let maxSummaryLength = 200

    // Memberwise initializer. Decodable's synthesized init still applies to the
    // file-loading path; this exists so pure policy/viewModel unit tests can
    // build windows directly off the JSON boundary.
    init(
        index: Int,
        name: String,
        command: String,
        active: Bool,
        statusKind: TmuxStatusKind,
        summary: String,
        target: String
    ) {
        self.index = index
        self.name = name
        self.command = command
        self.active = active
        self.statusKind = statusKind
        self.summary = summary
        self.target = target
    }
}

// MARK: - TmuxSession

// A tmux session and all its windows.
struct TmuxSession: Decodable {
    // Session name as returned by tmux list-sessions.
    let name: String
    // Whether any client is currently attached to this session.
    let attached: Bool
    // All windows in this session; may be empty.
    let windows: [TmuxWindow]
    // Unix epoch seconds of the session's last activity (tmux #{session_activity}).
    // Used to rank sessions by recency. Older status files omit it, so the decode
    // is lenient: absent → 0, which sorts the session to the "oldest" end.
    let activity: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case attached
        case windows
        case activity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        attached = try container.decode(Bool.self, forKey: .attached)
        windows = try container.decode([TmuxWindow].self, forKey: .windows)
        activity = try container.decodeIfPresent(Int.self, forKey: .activity) ?? 0
    }
}

// MARK: - TmuxStatusData

// Top-level container decoded from tmux-status.json.
// Written by the tmux-status skill running as a headless Claude process.
// Treat as untrusted external input — decode failures are handled by the caller.
struct TmuxStatusData: Decodable {
    // Unix epoch seconds at the time the file was written.
    let generatedAt: Int
    // All tmux sessions. Empty if tmux is not running.
    let sessions: [TmuxSession]
}
