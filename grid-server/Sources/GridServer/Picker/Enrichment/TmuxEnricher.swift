//
// TmuxEnricher.swift
// GridServer
//
// Detects tmux sessions attached to terminal windows.
// Uses ProcessTree to find which window PID has a tmux client descendant.
// Caches windowPID->clientPID mapping to disk (tmux-cache.json).
//

import Foundation

// MARK: - Data Types

struct TmuxClientInfo {
    let clientPID: pid_t
    let sessionName: String
    let windowName: String
    let windowIndex: Int
    let paneIndex: Int
    let paneCommand: String
    let claudeWaiting: Bool
}

struct TmuxCacheEntry: Codable {
    let clientPID: Int
    let cachedAt: Int64  // unix timestamp
}

struct TmuxCacheFile: Codable {
    var mappings: [String: TmuxCacheEntry]  // key = windowPID as string
}

/// Terminal bundle IDs that can run tmux
let terminalBundleIDs: Set<String> = [
    "com.mitchellh.ghostty",
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "io.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
]

// MARK: - TmuxEnricher

class TmuxEnricher {
    // clientPID -> TmuxClientInfo (from tmux list-clients)
    private var clients: [pid_t: TmuxClientInfo] = [:]

    // sessionName -> [windowName] (from tmux list-windows per session)
    private var sessionWindowsCache: [String: [String]] = [:]

    // windowPID -> clientPID (persisted to disk)
    private var pidCache: TmuxCacheFile

    private let cacheFilePath: String

    // MARK: - Init

    init() {
        cacheFilePath = thegridStateDir + "/tmux-cache.json"
        pidCache = TmuxEnricher.loadCacheFromDisk(cacheFilePath)
    }

    private static func loadCacheFromDisk(_ path: String) -> TmuxCacheFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode(TmuxCacheFile.self, from: data)
        else {
            return TmuxCacheFile(mappings: [:])
        }
        return decoded
    }

    // MARK: - Cache Refresh

    /// Refresh tmux client info via subprocess.
    /// MUST run on DispatchQueue.global() via runProcess.
    func refreshClients() async {
        let tmuxPath = findTmux()

        // Run tmux list-clients
        let output = await runProcess(
            tmuxPath,
            args: ["list-clients", "-F",
                   "#{client_pid}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{@claude-waiting}"]
        )

        guard let output, !output.isEmpty else {
            // tmux not running or not installed — non-fatal
            clients = [:]
            return
        }

        // Parse output into clients map
        var parsed: [pid_t: TmuxClientInfo] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
            guard parts.count >= 6 else { continue }
            guard let clientPID = pid_t(parts[0]) else { continue }
            let windowIndex = Int(parts[3]) ?? 0
            let paneIndex = Int(parts[4]) ?? 0
            // #{@claude-waiting} returns "1" when set, empty when unset
            let waiting = parts.count >= 7 && parts[6] == "1"
            parsed[clientPID] = TmuxClientInfo(
                clientPID: clientPID,
                sessionName: String(parts[1]),
                windowName: String(parts[2]),
                windowIndex: windowIndex,
                paneIndex: paneIndex,
                paneCommand: String(parts[5]),
                claudeWaiting: waiting
            )
        }
        clients = parsed

        // Refresh session windows cache: unique sessions -> window names
        let sessions = Set(clients.values.map(\.sessionName))
        var newWindowsCache: [String: [String]] = [:]
        for session in sessions {
            let windowsOutput = await runProcess(
                tmuxPath,
                args: ["list-windows", "-t", session, "-F", "#{window_name}"]
            )
            if let windowsOutput {
                let names = windowsOutput.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !names.isEmpty {
                    newWindowsCache[session] = names
                }
            }
        }
        sessionWindowsCache = newWindowsCache
    }

    // MARK: - Enrichment

    func supports(bundleID: String) -> Bool {
        return terminalBundleIDs.contains(bundleID)
    }

    /// Enrich a window PID by finding tmux client in its descendants.
    func enrich(pid: pid_t, tree: ProcessTree) -> EnrichmentResult? {
        // 1. Check disk cache first
        let pidKey = String(pid)
        if let entry = pidCache.mappings[pidKey] {
            let cachedClientPID = pid_t(entry.clientPID)
            if let info = clients[cachedClientPID] {
                return buildResult(info)
            }
        }

        // 2. Cache miss — search process tree (depth 4: login->shell->bash->tmux)
        let descendants = tree.getDescendants(of: pid, maxDepth: 4)
        for dpid in descendants {
            if let info = clients[dpid] {
                // Store in disk cache for next time
                pidCache.mappings[pidKey] = TmuxCacheEntry(
                    clientPID: Int(dpid),
                    cachedAt: Int64(Date().timeIntervalSince1970)
                )
                return buildResult(info)
            }
        }

        return nil
    }

    // MARK: - Result Building

    private func buildResult(_ info: TmuxClientInfo) -> EnrichmentResult {
        let windowNames = sessionWindowsCache[info.sessionName] ?? []

        var subtitle = "\(info.sessionName):\(info.windowName)"
        if !windowNames.isEmpty {
            subtitle += " [" + windowNames.joined(separator: " | ") + "]"
        } else if !info.paneCommand.isEmpty {
            subtitle += " [\(info.paneCommand)]"
        }

        return EnrichmentResult(
            title: info.sessionName,
            subtitle: subtitle,
            stableIDSuffix: "\(info.sessionName):\(info.windowName)",
            kind: .tmux,
            claudeWaiting: info.claudeWaiting
        )
    }

    // MARK: - Cache Persistence

    func pruneCache() {
        // Remove entries whose clientPID is no longer in current clients
        let validPIDs = Set(clients.keys.map { Int($0) })
        pidCache.mappings = pidCache.mappings.filter { _, entry in
            validPIDs.contains(entry.clientPID)
        }
    }

    func saveCache() {
        pruneCache()

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: thegridStateDir,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pidCache) else {
            jlog("tmux.cache.encode_err")
            return
        }
        try? data.write(to: URL(fileURLWithPath: cacheFilePath))
    }
}
