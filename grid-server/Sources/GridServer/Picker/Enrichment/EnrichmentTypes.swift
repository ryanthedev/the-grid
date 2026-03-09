//
// EnrichmentTypes.swift
// GridServer
//
// Shared types and subprocess helper for all enrichers.
//

import Foundation

// MARK: - Enrichment Result

/// Formatted output from an enricher
struct EnrichmentResult {
    let title: String
    let subtitle: String
    let stableIDSuffix: String
    let kind: EnrichmentKind
}

enum EnrichmentKind {
    case tmux
    case ssh
    case sshAndTmux
    case chrome
}

// MARK: - Subprocess Error

enum SubprocessError: Error {
    case nonZeroExit
    case notFound
}

// MARK: - Subprocess Helper

/// Run a subprocess on DispatchQueue.global(), NOT the cooperative thread pool.
/// Returns stdout as String?, nil on any error (including non-zero exit).
func runProcess(_ executable: String, args: [String]) async -> String? {
    return try? await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                // Read pipe BEFORE waitUntilExit to avoid deadlock.
                // If the subprocess writes more than the pipe buffer (64KB),
                // it blocks on write until someone reads — calling
                // waitUntilExit first would deadlock.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: SubprocessError.nonZeroExit)
                    return
                }

                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output ?? "")
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Tmux Path Helper

/// Find tmux binary by checking known absolute paths.
/// Server has minimal PATH, so check absolute paths rather than relying on env.
func findTmux() -> String {
    let candidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    // Fallback — if none found, commands will fail gracefully
    return "/usr/bin/tmux"
}

// MARK: - State Directory

/// XDG-compliant state directory for thegrid.
/// Matches the spec in CLAUDE.md: $XDG_STATE_HOME/thegrid (default ~/.local/state/thegrid)
var thegridStateDir: String {
    return XDG.stateHome + "/thegrid"
}
