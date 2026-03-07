# Phase 2 Pseudocode: Enrichment + History

## 1. ProcessTree.swift

**File:** `grid-server/Sources/GridServer/Picker/Enrichment/ProcessTree.swift`

**Purpose:** Build a process tree from `ps -eo pid,ppid` and provide depth-limited descendant lookup. Cached per discovery session. All subprocess calls run on `DispatchQueue.global()` via `Process`, NOT the Swift cooperative thread pool.

```
class ProcessTree {
    // parent PID -> [child PIDs]
    private var children: [pid_t: [pid_t]] = [:]

    // MARK: - Factory (runs subprocess off cooperative pool)

    // Build tree by running `ps -eo pid,ppid` on DispatchQueue.global()
    // Bridge to async via withCheckedThrowingContinuation
    static func build() async -> ProcessTree

        tree = ProcessTree()

        // Bridge Process to async — MUST use DispatchQueue.global(), not Task
        let output: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-eo", "pid,ppid"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Parse output (skip header line)
        let lines = output.split(separator: "\n").dropFirst()
        for line in lines:
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            guard let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            tree.children[ppid, default: []].append(pid)

        return tree

    // MARK: - Descendant Lookup

    // BFS up to maxDepth levels, returns flat array of all descendant PIDs
    func getDescendants(of parentPID: pid_t, maxDepth: Int) -> [pid_t]

        guard maxDepth > 0 else { return [] }

        var result: [pid_t] = []
        // Use queue for BFS (matches Go's recursive DFS but BFS is cleaner)
        var queue: [(pid: pid_t, depth: Int)] = [(parentPID, 0)]
        var head = 0

        while head < queue.count:
            let (current, depth) = queue[head]
            head += 1

            guard depth < maxDepth else { continue }

            let kids = children[current] ?? []
            result.append(contentsOf: kids)
            for kid in kids:
                queue.append((kid, depth + 1))

        return result
}
```

**Key decisions:**
- Class (not struct) because it holds mutable cached state
- `build()` is async factory but internally dispatches to global queue
- BFS instead of Go's recursive DFS — same result, iterative
- No global singleton cache — caller (WindowEnricher) holds the tree per session

---

## 2. TmuxEnricher.swift

**File:** `grid-server/Sources/GridServer/Picker/Enrichment/TmuxEnricher.swift`

**Purpose:** Detect tmux sessions attached to terminal windows. Run `tmux list-clients` to get client info, then use ProcessTree to find which window PID has a tmux client descendant. Cache windowPID->clientPID mapping to disk.

```
// Port of Go TmuxClientInfo
struct TmuxClientInfo {
    let clientPID: pid_t
    let sessionName: String
    let windowName: String
    let windowIndex: Int
    let paneIndex: Int
    let paneCommand: String
}

// Port of Go tmux.Cache — windowPID -> clientPID mapping
struct TmuxCacheEntry: Codable {
    let clientPID: Int
    let cachedAt: Int64  // unix timestamp
}

struct TmuxCacheFile: Codable {
    var mappings: [String: TmuxCacheEntry]  // key = windowPID as string
}

// Known terminal bundle IDs (from Go tmux/terminals.go)
let terminalBundleIDs: Set<String> = [
    "com.mitchellh.ghostty",
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "io.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
]

class TmuxEnricher {
    // clientPID -> TmuxClientInfo (from tmux list-clients)
    private var clients: [pid_t: TmuxClientInfo] = [:]

    // sessionName -> [windowName] (from tmux list-windows per session)
    private var sessionWindowsCache: [String: [String]] = [:]

    // windowPID -> clientPID (persisted to disk)
    private var pidCache: TmuxCacheFile

    private let cacheFilePath: String
        // ~/.local/state/thegrid/tmux-cache.json

    // MARK: - Init

    init()
        cacheFilePath = stateDir + "/tmux-cache.json"
        pidCache = loadCacheFromDisk(cacheFilePath)
            // Read JSON file, decode TmuxCacheFile
            // If missing or corrupt, return TmuxCacheFile(mappings: [:])

    // MARK: - Cache Refresh (called once per discovery session)

    // Refresh tmux client info via subprocess
    // MUST run on DispatchQueue.global() via Process
    func refreshClients() async

        // 1. Find tmux binary
        let tmuxPath = findTmux()
            // Check in order: "tmux" via PATH, /opt/homebrew/bin/tmux,
            //   /usr/local/bin/tmux, /usr/bin/tmux
            // Use FileManager.default.isExecutableFile(atPath:) for absolute paths
            // Use Process with /usr/bin/which for PATH lookup

        // 2. Run `tmux list-clients -F "format_string"` on global queue
        let output = await runProcess(
            tmuxPath,
            args: ["list-clients", "-F",
                   "#{client_pid}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}"]
        )
        // runProcess returns String? — nil on error (tmux not running, etc.)
        // Errors are non-fatal — just means no tmux enrichment

        guard let output else {
            clients = [:]
            return
        }

        // 3. Parse output into clients map
        var parsed: [pid_t: TmuxClientInfo] = [:]
        for line in output.split(separator: "\n"):
            let parts = line.split(separator: "|", maxSplits: 5)
            guard parts.count == 6 else { continue }
            guard let clientPID = pid_t(parts[0]) else { continue }
            let windowIndex = Int(parts[3]) ?? 0
            let paneIndex = Int(parts[4]) ?? 0
            parsed[clientPID] = TmuxClientInfo(
                clientPID: clientPID,
                sessionName: String(parts[1]),
                windowName: String(parts[2]),
                windowIndex: windowIndex,
                paneIndex: paneIndex,
                paneCommand: String(parts[5])
            )
        clients = parsed

        // 4. Refresh session windows cache
        // Collect unique session names
        let sessions = Set(clients.values.map(\.sessionName))
        var newCache: [String: [String]] = [:]
        for session in sessions:
            // Run `tmux list-windows -t {session} -F "#{window_name}"` on global queue
            let windowsOutput = await runProcess(
                tmuxPath,
                args: ["list-windows", "-t", session, "-F", "#{window_name}"]
            )
            if let windowsOutput:
                let names = windowsOutput.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                newCache[session] = names
        sessionWindowsCache = newCache

    // MARK: - Enrichment

    func supports(bundleID: String) -> Bool
        return terminalBundleIDs.contains(bundleID)

    // Enrich a window PID by finding tmux client in its descendants
    func enrich(pid: pid_t, tree: ProcessTree) -> EnrichmentResult?

        // 1. Check disk cache first
        let pidKey = String(pid)
        if let entry = pidCache.mappings[pidKey]:
            let cachedClientPID = pid_t(entry.clientPID)
            if let info = clients[cachedClientPID]:
                return buildResult(info)

        // 2. Cache miss — search process tree (depth 4)
        let descendants = tree.getDescendants(of: pid, maxDepth: 4)
        for dpid in descendants:
            if let info = clients[dpid]:
                // Store in disk cache for next time
                pidCache.mappings[pidKey] = TmuxCacheEntry(
                    clientPID: Int(dpid),
                    cachedAt: Int64(Date().timeIntervalSince1970)
                )
                return buildResult(info)

        return nil

    // MARK: - Result Building

    private func buildResult(_ info: TmuxClientInfo) -> EnrichmentResult
        let windowNames = sessionWindowsCache[info.sessionName] ?? []

        // Build subtitle
        var subtitle = "\(info.sessionName):\(info.windowName)"
        if !windowNames.isEmpty:
            subtitle += " [" + windowNames.joined(separator: " | ") + "]"
        else if !info.paneCommand.isEmpty:
            subtitle += " [" + info.paneCommand + "]"

        return EnrichmentResult(
            title: info.sessionName,
            subtitle: subtitle,
            stableIDSuffix: "\(info.sessionName):\(info.windowName)",
            kind: .tmux
        )

    // MARK: - Cache Persistence

    func pruneCache()
        // Remove entries whose clientPID is no longer in current clients
        let validPIDs = Set(clients.keys.map { Int($0) })
        pidCache.mappings = pidCache.mappings.filter { _, entry in
            validPIDs.contains(entry.clientPID)
        }

    func saveCache()
        pruneCache()
        // Write pidCache as JSON to cacheFilePath
        // Non-fatal if write fails (log and continue)
        let data = try? JSONEncoder().encode(pidCache)
        // indent for readability
        try? data?.write(to: URL(fileURLWithPath: cacheFilePath))
}

// MARK: - Subprocess Helper (shared by all enrichers)

// Run a subprocess on DispatchQueue.global(), NOT cooperative thread pool
// Returns stdout as String?, nil on any error
func runProcess(_ executable: String, args: [String]) async -> String?

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
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: SubprocessError.nonZeroExit)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

// Note: findTmux() also goes here or in a shared util
func findTmux() -> String
    let candidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]
    for path in candidates:
        if FileManager.default.isExecutableFile(atPath: path):
            return path
    return "/usr/bin/tmux"  // fallback
```

**Key decisions:**
- `runProcess` is the shared subprocess bridge used by all enrichers
- ProcessTree is passed in (not owned) — built once in WindowEnricher
- Disk cache uses same JSON schema as Go version for potential cross-compat
- `findTmux()` checks absolute paths (server has minimal PATH)

---

## 3. SSHEnricher.swift

**File:** `grid-server/Sources/GridServer/Picker/Enrichment/SSHEnricher.swift`

**Purpose:** Detect SSH connections in Ghostty windows. Build a PID->isSSH cache from `ps -ax -o pid=,comm=`, then search process tree (depth 6) for ssh processes. Parse SSH args for user/host.

```
class SSHEnricher {
    // Set of PIDs that are ssh processes (from ps cache)
    private var sshPIDs: Set<pid_t> = []

    // Only supports Ghostty
    private let supportedBundleIDs: Set<String> = [
        "com.mitchellh.ghostty"
    ]

    // MARK: - Cache Refresh

    // Build SSH process cache from `ps -ax -o pid=,comm=`
    // Called once per discovery session from WindowEnricher.refreshCaches()
    func refreshCache() async

        let output = await runProcess("/bin/ps", args: ["-ax", "-o", "pid=,comm="])
        guard let output else {
            sshPIDs = []
            return
        }

        var pids: Set<pid_t> = []
        for line in output.split(separator: "\n"):
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            guard let pid = pid_t(fields[0]) else { continue }
            let comm = String(fields[1])
            if comm == "ssh":
                pids.insert(pid)
        sshPIDs = pids

    // MARK: - Enrichment

    func supports(bundleID: String) -> Bool
        return supportedBundleIDs.contains(bundleID)

    // Enrich a window PID by finding ssh process in its descendants
    func enrich(pid: pid_t, windowTitle: String, tree: ProcessTree) async -> EnrichmentResult?

        // 1. Search process tree (depth 6 for login->shell->bash->zsh->script->ssh)
        let descendants = tree.getDescendants(of: pid, maxDepth: 6)

        var sshPID: pid_t = 0
        for dpid in descendants:
            if sshPIDs.contains(dpid):
                sshPID = dpid
                break

        guard sshPID != 0 else { return nil }

        // 2. Get SSH command line: `ps -o args= -p {sshPID}`
        let argsOutput = await runProcess("/bin/ps", args: ["-o", "args=", "-p", "\(sshPID)"])
        guard let argsOutput, !argsOutput.isEmpty else { return nil }

        // 3. Parse SSH args for user@host
        guard let (user, host) = parseSSHArgs(argsOutput) else { return nil }

        // 4. Extract title context (remote cwd/command from window title)
        let (remoteCwd, remoteCommand) = extractTitleContext(windowTitle)

        // 5. Build result
        var subtitle = ""
        if !remoteCwd.isEmpty && !remoteCommand.isEmpty:
            subtitle = "\(remoteCwd): \(remoteCommand)"
        else if !remoteCwd.isEmpty:
            subtitle = remoteCwd
        else if !remoteCommand.isEmpty:
            subtitle = remoteCommand

        return EnrichmentResult(
            title: "\(user)@\(host)",
            subtitle: subtitle,
            stableIDSuffix: "\(user)@\(host)",
            kind: .ssh
        )

    // MARK: - SSH Arg Parsing

    // Parse SSH command line to extract user and host
    // Handles: ssh user@host, ssh -l user host, ssh host (uses current user)
    // Skips flags with values: -l, -p, -i, -o, -F, -J, -D, -L, -R, -W, -b, -c, -e, -m, -S, -w
    static func parseSSHArgs(_ args: String) -> (user: String, host: String)?

        let parts = args.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2 else { return nil }

        let flagsWithValues: Set<String> = [
            "-l", "-p", "-i", "-o", "-F", "-J",
            "-D", "-L", "-R", "-W", "-b", "-c",
            "-e", "-m", "-S", "-w"
        ]

        var positionalArgs: [String] = []
        var extractedUser: String = ""
        var i = 1  // skip "ssh" at index 0

        while i < parts.count:
            let arg = parts[i]

            if arg == "-l" && i + 1 < parts.count:
                extractedUser = parts[i + 1]
                i += 2
                continue

            if flagsWithValues.contains(arg) && i + 1 < parts.count:
                i += 2  // skip flag + value
                continue

            if arg.hasPrefix("-"):
                i += 1
                continue

            positionalArgs.append(arg)
            i += 1

        guard !positionalArgs.isEmpty else { return nil }

        let destination = positionalArgs[0]

        if let atIndex = destination.lastIndex(of: "@"):
            let user = String(destination[..<atIndex])
            let host = String(destination[destination.index(after: atIndex)...])
            guard !host.isEmpty else { return nil }
            return (user, host)
        else:
            let host = destination
            var user = extractedUser
            if user.isEmpty:
                user = NSUserName()  // current macOS username
            guard !host.isEmpty else { return nil }
            return (user, host)

    // MARK: - Title Context Parsing

    // Parse window title for remote cwd/command
    // Format: "~path: command" or "/path: command"
    static func extractTitleContext(_ title: String) -> (cwd: String, command: String)

        guard let colonIdx = title.range(of: ": ") else {
            return ("", "")
        }

        let prefix = String(title[..<colonIdx.lowerBound])
        let suffix = String(title[colonIdx.upperBound...]).trimmingCharacters(in: .whitespaces)

        if prefix.hasPrefix("~") || prefix.hasPrefix("/"):
            return (prefix, suffix)
        else if suffix.hasPrefix("~") || suffix.hasPrefix("/"):
            return (suffix, "")
        else:
            return ("", suffix)
}
```

**Key decisions:**
- `parseSSHArgs` and `extractTitleContext` are `static` — pure functions, easy to unit test
- ProcessTree passed in from WindowEnricher (shared with TmuxEnricher)
- SSH args lookup (`ps -o args= -p PID`) is per-ssh-process, async via runProcess
- Only Ghostty supported (matches Go code)

---

## 4. ChromeEnricher.swift

**File:** `grid-server/Sources/GridServer/Picker/Enrichment/ChromeEnricher.swift`

**Purpose:** Detect Chrome profile from window title regex. Read Chrome Local State JSON for profile metadata (email, directory). No subprocess calls — file I/O only.

```
class ChromeEnricher {
    // profileDir -> ProfileInfo (from Local State JSON)
    private var infoCache: [String: ProfileInfo] = [:]

    // displayName -> profileDir (reverse lookup)
    private var nameToDir: [String: String] = [:]

    // Loaded flag (load once lazily)
    private var loaded = false

    // Supported bundle IDs
    private let supportedBundleIDs: Set<String> = [
        "com.google.Chrome"
    ]

    // Regex: "Page Title - Google Chrome - Profile Name"
    // Captures profile name after browser identifier
    private static let profilePattern = try! NSRegularExpression(
        pattern: #"- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$"#
    )

    struct ProfileInfo {
        let name: String
        let gaiaName: String
        let userName: String
    }

    // MARK: - Enrichment

    func supports(bundleID: String) -> Bool
        return supportedBundleIDs.contains(bundleID)

    func enrich(windowTitle: String) -> EnrichmentResult?

        // 1. Regex match for profile suffix
        let nsTitle = windowTitle as NSString
        let range = NSRange(location: 0, length: nsTitle.length)
        let match = Self.profilePattern.firstMatch(in: windowTitle, range: range)

        if match == nil:
            // No profile suffix = Default profile
            return EnrichmentResult(
                title: windowTitle,  // clean title (no suffix to strip)
                subtitle: "Default",
                stableIDSuffix: "chrome:Default",
                kind: .chrome
            )

        // Extract profile name (capture group 1)
        let profileNameRange = match!.range(at: 1)
        let profileName = nsTitle.substring(with: profileNameRange)

        // Extract clean page title (everything before the regex match)
        let pageTitle = nsTitle.substring(to: match!.range.location)
            .trimmingCharacters(in: .whitespaces)

        // 2. Load Local State (once, lazily)
        if !loaded:
            loadLocalState()
            loaded = true

        // 3. Lookup profile dir and email
        var profileDir = ""
        var email = ""
        if let dir = nameToDir[profileName]:
            profileDir = dir
            if let info = infoCache[dir]:
                email = info.userName

        // 4. Build result
        let subtitle: String
        if !email.isEmpty:
            subtitle = "\(profileName) (\(email))"
        else:
            subtitle = profileName

        return EnrichmentResult(
            title: pageTitle.isEmpty ? windowTitle : pageTitle,
            subtitle: subtitle,
            stableIDSuffix: "chrome:\(profileName)",
            kind: .chrome
        )

    // MARK: - Local State Loading

    private func loadLocalState()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localStatePath = "\(home)/Library/Application Support/Google/Chrome/Local State"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)) else {
            return  // Chrome not installed — silent
        }

        // Parse JSON structure
        // Expected: { "profile": { "info_cache": { "Default": { "name": ..., "gaia_name": ..., "user_name": ..., "is_using_default_name": ... }, ... } } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoMap = profile["info_cache"] as? [String: [String: Any]]
        else { return }

        for (dir, info) in infoMap:
            let name = info["name"] as? String ?? ""
            let gaiaName = info["gaia_name"] as? String ?? ""
            let userName = info["user_name"] as? String ?? ""
            let isDefault = info["is_using_default_name"] as? Bool ?? false

            infoCache[dir] = ProfileInfo(name: name, gaiaName: gaiaName, userName: userName)

            // Build reverse lookup: displayName -> dir
            // Same logic as Go: prefer name unless isDefault, then gaiaName
            var displayName = name
            if displayName.isEmpty || isDefault:
                if !gaiaName.isEmpty:
                    displayName = gaiaName
            if !displayName.isEmpty:
                nameToDir[displayName] = dir
}
```

**Key decisions:**
- No subprocess calls — reads Local State JSON from filesystem directly
- Lazy loading (first enrich call triggers loadLocalState)
- Uses JSONSerialization instead of Codable for flexibility with Chrome's complex JSON
- `pid` parameter not needed (Chrome uses window title, not process tree)

---

## 5. WindowEnricher.swift

**File:** `grid-server/Sources/GridServer/Picker/Enrichment/WindowEnricher.swift`

**Purpose:** Registry combining all three enrichers. Single entry point for WindowSource. Owns the ProcessTree for the current discovery session.

```
// Result type returned by enrichers
struct EnrichmentResult {
    let title: String
    let subtitle: String
    let stableIDSuffix: String
    let kind: EnrichmentKind
}

enum EnrichmentKind {
    case tmux
    case ssh
    case sshAndTmux  // when both found
    case chrome
}

class WindowEnricher {
    private let tmuxEnricher = TmuxEnricher()
    private let sshEnricher = SSHEnricher()
    private let chromeEnricher = ChromeEnricher()

    // Process tree for current session (rebuilt per discovery)
    private var processTree: ProcessTree?

    // MARK: - Session Lifecycle

    // Call once at start of each discovery session
    // Refreshes all caches in parallel (subprocess calls)
    func refreshCaches() async

        // Build process tree + refresh enricher caches in parallel
        async let tree = ProcessTree.build()
        async let _ = tmuxEnricher.refreshClients()
        async let _ = sshEnricher.refreshCache()

        processTree = await tree
        // await the other two (fire-and-forget pattern)

    // MARK: - Enrichment

    // Enrich a single window. Returns nil if no enrichment applies.
    func enrich(bundleID: String, pid: pid_t, title: String) async -> EnrichmentResult?

        guard let tree = processTree else { return nil }

        // Try enrichers in order, merge results (SSH + Tmux can combine)
        var sshResult: EnrichmentResult? = nil
        var tmuxResult: EnrichmentResult? = nil

        // SSH enrichment (Ghostty only)
        if sshEnricher.supports(bundleID: bundleID):
            sshResult = await sshEnricher.enrich(pid: pid, windowTitle: title, tree: tree)

        // Tmux enrichment (all terminals)
        if tmuxEnricher.supports(bundleID: bundleID):
            tmuxResult = tmuxEnricher.enrich(pid: pid, tree: tree)

        // Chrome enrichment
        if chromeEnricher.supports(bundleID: bundleID):
            return chromeEnricher.enrich(windowTitle: title)

        // Combine SSH + Tmux results
        if let ssh = sshResult, let tmux = tmuxResult:
            // SSH+Tmux combo: title from SSH, subtitle from tmux
            var subtitle = "\(tmux.subtitle)"
            // stableIDSuffix: user@host/session:window
            let suffix = "\(ssh.stableIDSuffix)/\(tmux.stableIDSuffix)"
            return EnrichmentResult(
                title: ssh.title,
                subtitle: subtitle,
                stableIDSuffix: suffix,
                kind: .sshAndTmux
            )

        // SSH only
        if let ssh = sshResult:
            return ssh

        // Tmux only
        if let tmux = tmuxResult:
            return tmux

        return nil

    // MARK: - Cleanup

    // Persist caches to disk (called after discovery completes)
    func cleanup()
        tmuxEnricher.saveCache()
}
```

**Key decisions:**
- ProcessTree is rebuilt per discovery session (not cached forever)
- SSH and Tmux can both apply to same window (Ghostty + tmux over SSH)
- Chrome is exclusive (no terminal enrichment for Chrome windows)
- Enrichers tried in order: SSH, Tmux, Chrome — matches Go registry pattern
- `cleanup()` called after discovery to persist tmux cache

---

## 6. PickerHistory.swift

**File:** `grid-server/Sources/GridServer/Picker/PickerHistory.swift`

**Purpose:** Track picker selection frequency and recency. Persist to JSON file. Provide frecency scoring and source-boost sorting.

```
class PickerHistory {
    static let maxEntries = 100
    static let historyVersion = 1

    // File path: ~/.local/state/thegrid/picker-history.json
    private let filePath: String

    // Schema fields
    var version: Int = 1
    var previous: String = ""
    var frequency: [String: Int] = [:]
    var lastPicked: [String: Int64] = [:]  // unix timestamp

    // MARK: - Init / Load

    init()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        filePath = "\(home)/.local/state/thegrid/picker-history.json"

    // Load from disk. Returns fresh history if file missing or corrupt.
    static func load() -> PickerHistory
        let history = PickerHistory()

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: history.filePath)) else {
            return history  // no file = fresh history
        }

        // Decode JSON
        struct HistoryFile: Codable {
            var version: Int
            var previous: String
            var frequency: [String: Int]
            var lastPicked: [String: Int64]
        }

        guard let decoded = try? JSONDecoder().decode(HistoryFile.self, from: data) else {
            jlog("pick.hist.parse_err")
            return history  // corrupt file = fresh history
        }

        // Validate (no negative frequencies or timestamps)
        for (id, freq) in decoded.frequency:
            guard freq >= 0 else {
                jlog("pick.hist.invalid", data: ["id": id])
                return history
            }
        for (id, ts) in decoded.lastPicked:
            guard ts >= 0 else {
                jlog("pick.hist.invalid", data: ["id": id])
                return history
            }

        history.version = decoded.version
        history.previous = decoded.previous
        history.frequency = decoded.frequency
        history.lastPicked = decoded.lastPicked
        return history

    // MARK: - Record Selection

    func recordSelection(_ stableID: String)
        guard !stableID.isEmpty else { return }
        previous = stableID
        frequency[stableID, default: 0] += 1
        lastPicked[stableID] = Int64(Date().timeIntervalSince1970)

    // MARK: - Frecency Scoring

    // frecencyScore = frequency * (1.0 / (1.0 + hoursSince / 24.0))
    // Returns 0 for unknown items
    func frecencyScore(_ id: String) -> Double
        guard let freq = frequency[id], freq > 0 else { return 0 }

        guard let lastTS = lastPicked[id], lastTS > 0 else {
            return Double(freq)
        }

        let hoursSince = Date().timeIntervalSince(Date(timeIntervalSince1970: Double(lastTS))) / 3600.0
        let recencyWeight = 1.0 / (1.0 + hoursSince / 24.0)
        return Double(freq) * recencyWeight

    // MARK: - Source Boosts

    // Source boost multipliers by item ID prefix
    static func sourceBoost(for id: String) -> Double
        if id.hasPrefix("app:"):       return 1.0
        if id.hasPrefix("chrome:"):    return 1.0
        if id.hasPrefix("action:"):    return 1.5
        if id.hasPrefix("zoxide:"):    return 0.5
        // Windows: tmux:*, ssh:*, bundleID:*, unknown:*
        return 10.0

    // MARK: - Sorting

    // Sort items by finalScore = max(frecency, 1.0) * sourceBoost, descending
    // Stable sort preserves original order for equal scores
    func sortByFrecency(_ items: inout [PickerItem])
        items.sort { a, b in
            let scoreA = finalScore(a.id)
            let scoreB = finalScore(b.id)
            if scoreA != scoreB:
                return scoreA > scoreB
            // Equal scores: preserve priority ordering
            return a.priority > b.priority
        }
        // Note: Swift's sort is NOT stable. Use a manual stable sort or
        // add an index tiebreaker:
        // Actually, use sorted() approach with enumerated indices for stability
        // OR: append original index to comparison

    // Combined score with source boost
    private func finalScore(_ id: String) -> Double
        var base = frecencyScore(id)
        if base == 0:
            base = 1.0  // ensure boosts still apply to unscored items
        return base * Self.sourceBoost(for: id)

    // MARK: - Pruning

    // Remove oldest entries if over maxEntries, by lastPicked LRU
    func prune()
        guard frequency.count > Self.maxEntries else { return }

        // Sort entries by lastPicked ascending (oldest first)
        let sorted = frequency.keys.sorted { a, b in
            (lastPicked[a] ?? 0) < (lastPicked[b] ?? 0)
        }

        // Remove oldest until at maxEntries
        let toRemove = sorted.count - Self.maxEntries
        for i in 0..<toRemove:
            let id = sorted[i]
            frequency.removeValue(forKey: id)
            lastPicked.removeValue(forKey: id)

    // MARK: - Save

    // Atomic write: prune, write to .tmp, rename
    func save()
        prune()

        // Ensure directory exists
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        struct HistoryFile: Codable {
            var version: Int
            var previous: String
            var frequency: [String: Int]
            var lastPicked: [String: Int64]
        }

        let file = HistoryFile(
            version: version,
            previous: previous,
            frequency: frequency,
            lastPicked: lastPicked
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            jlog("pick.hist.encode_err")
            return
        }

        // Atomic write via temp file
        let tmpPath = filePath + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath))
            try FileManager.default.moveItem(atPath: tmpPath, toPath: filePath)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
            jlog("pick.hist.save_err", data: ["err": "\(error)"])
        }

    // MARK: - Helpers

    func isPrevious(_ id: String) -> Bool
        return !previous.isEmpty && previous == id
}
```

**Key decisions:**
- Loaded once on server start, saved on each selection
- `sortByFrecency` operates in-place on `[PickerItem]` (needs stable sort consideration)
- Source boost for windows is 10.0 (catches tmux:, ssh:, bundleID: prefixes)
- Atomic save matches Go pattern (temp + rename)
- `HistoryFile` Codable struct used for serialization (private, inner)

---

## 7. WindowSource.swift Modifications

**File:** `grid-server/Sources/GridServer/Picker/WindowSource.swift` (modify existing)

**Changes:** Add enrichment via WindowEnricher. Generate stable window IDs. Use enriched titles/subtitles.

```
struct WindowSource: PickerSource {
    let id = "windows"

    // Injected by PickerManager (shared across sources in same session)
    let enricher: WindowEnricher

    func discover() async throws -> [PickerItem]

        // 1. Refresh enricher caches (subprocess calls for tmux, ssh, ps)
        await enricher.refreshCaches()

        // 2. Get windows from StateManager (unchanged)
        let state = await StateManager.shared.getState()

        var items: [PickerItem] = []

        for (windowIDStr, window) in state.windows:
            // --- Existing filters (unchanged) ---
            guard !window.isHidden, !window.isMinimized else { continue }
            guard window.alpha > 0.01 else { continue }
            if let subrole = window.subrole, subrole != "AXStandardWindow":
                continue

            // --- App info lookup (unchanged) ---
            let pidStr = "\(window.pid)"
            let app = state.applications[pidStr]
            let appName = window.appName ?? app?.localizedName ?? "Unknown"
            let bundleID = app?.bundleIdentifier ?? ""
            let windowTitle = window.title ?? ""

            // --- NEW: Enrichment ---
            let enrichment = await enricher.enrich(
                bundleID: bundleID,
                pid: pid_t(window.pid),
                title: windowTitle
            )

            // --- NEW: Build title/subtitle from enrichment ---
            let title: String
            let subtitle: String?

            if let e = enrichment:
                // Enriched: use enricher's title/subtitle
                title = "\(appName) — \(e.title)"
                subtitle = e.subtitle
            else:
                // Non-enriched: existing logic
                if !windowTitle.isEmpty && windowTitle != appName:
                    title = "\(appName) — \(windowTitle)"
                else:
                    title = appName
                subtitle = bundleID.isEmpty ? nil : bundleID

            // --- NEW: Stable window ID ---
            let wid = Int(windowIDStr) ?? 0
            let stableID = generateStableID(
                wid: wid,
                enrichment: enrichment,
                bundleID: bundleID,
                title: windowTitle,
                pid: window.pid
            )

            // --- Icon, searchable, metadata (mostly unchanged) ---
            let icon: String? = bundleID.isEmpty ? nil : "bundle:\(bundleID)"

            var searchable = [appName]
            if !windowTitle.isEmpty:
                searchable.append(windowTitle)
            if !bundleID.isEmpty:
                searchable.append(bundleID)
            // NEW: add enriched title to searchable
            if let e = enrichment:
                searchable.append(e.title)
                if !e.subtitle.isEmpty:
                    searchable.append(e.subtitle)

            var metadata: [String: String] = [
                "action": "focusWindow",
                "pid": "\(window.pid)",
                "windowID": windowIDStr
            ]
            if !bundleID.isEmpty:
                metadata["bundleID"] = bundleID

            let item = PickerItem(
                id: stableID,   // CHANGED: was "win-\(windowIDStr)"
                title: title,
                subtitle: subtitle,
                icon: icon,
                searchable: searchable,
                metadata: metadata,
                priority: 1000
            )
            items.append(item)

        // Cleanup enricher caches (persist tmux cache)
        enricher.cleanup()

        // Sort by title
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return items
}

// MARK: - Stable Window ID Generation

// Port of Go stableWindowID()
func generateStableID(
    wid: Int,
    enrichment: EnrichmentResult?,
    bundleID: String,
    title: String,
    pid: Int32
) -> String

    // Enriched windows use stableIDSuffix
    if let e = enrichment, !e.stableIDSuffix.isEmpty:
        let suffix = e.stableIDSuffix
        switch e.kind:
        case .tmux:
            return "tmux:\(suffix)"
        case .ssh:
            return "ssh:\(suffix)"
        case .sshAndTmux:
            return "ssh:\(suffix)"
        case .chrome:
            return suffix  // already has "chrome:" prefix

    // Non-enriched with bundleID
    if !bundleID.isEmpty:
        if !title.isEmpty && title != "Untitled":
            let normalized = normalizeTitle(title)
            if !normalized.isEmpty:
                return "\(bundleID):\(normalized):\(hash4(title))"
        return "\(bundleID):untitled:\(wid)"

    // Fallback
    return "unknown:\(wid)"

// Port of Go normalizeTitle()
// lowercase -> replace [^a-z0-9]+ with "-" -> trim hyphens -> truncate 30 -> trim trailing hyphen
func normalizeTitle(_ title: String) -> String
    var result = title.lowercased()

    // Replace non-alphanumeric runs with hyphens
    let regex = try! NSRegularExpression(pattern: "[^a-z0-9]+")
    result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "-"
    )

    // Trim leading/trailing hyphens
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    // Truncate to 30 chars
    if result.count > 30:
        result = String(result.prefix(30))

    // Trim trailing hyphen after truncation
    if result.hasSuffix("-"):
        result = String(result.dropLast())

    return result

// Port of Go hash4() — first 4 hex chars of SHA256
func hash4(_ s: String) -> String
    import CryptoKit
    let digest = SHA256.hash(data: Data(s.utf8))
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(4))
```

**Key decisions:**
- `enricher` is injected (created by PickerManager, shared per session)
- Stable ID replaces the old `"win-\(windowIDStr)"` — enables history tracking across restarts
- Enriched title/subtitle added to searchable array for fuzzy matching
- `normalizeTitle` and `hash4` are free functions (used only here)

---

## 8. PickerManager.swift Modifications

**File:** `grid-server/Sources/GridServer/Picker/PickerManager.swift` (modify existing)

**Changes:** Load history on server start. Sort items by frecency after each source batch. Record selection on pick.

```
class PickerManager {
    static let shared = PickerManager()

    private var window: PickerWindow?
    private var discoveryTask: Task<Void, Never>?
    private var isVisible = false
    private var isActivating = false
    private var activationGraceTimer: DispatchWorkItem?

    // NEW: History (loaded once on init, persisted on selection)
    private var history: PickerHistory

    // NEW: All items accumulated during current session (for re-sorting)
    private var allItems: [PickerItem] = []

    private init()
        // Load history from disk on server start
        history = PickerHistory.load()
        jlog("pick.hist.loaded", data: [
            "entries": "\(history.frequency.count)",
            "previous": history.previous
        ])

    // MARK: - Show / Hide

    func show()
        dispatchPrecondition(condition: .onQueue(.main))

        if isVisible:
            hide()
            return

        isVisible = true
        allItems = []  // NEW: reset accumulated items

        // ... (existing window creation, policy switch, activation — unchanged) ...

        if window == nil:
            window = PickerWindow()
            window!.onResult = { [weak self] result in
                self?.handleResult(result)
            }
            NotificationCenter.default.addObserver(...)

        window!.resetForNewShow()
        window!.setLoading(true)

        isActivating = true
        activationGraceTimer?.cancel()
        NSApp.setActivationPolicy(.regular)
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window!.focusInput()

        let graceWork = DispatchWorkItem { [weak self] in
            self?.isActivating = false
        }
        activationGraceTimer = graceWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: graceWork)

        discoveryTask = Task { [weak self] in
            await self?.discoverAndStream()
        }

        jlog("pick.show")

    func hide()
        // ... (unchanged) ...

    // MARK: - Result Handling

    private func handleResult(_ result: PickerResult)
        hide()

        switch result:
        case .selected(let item):
            // NEW: Record selection in history
            history.recordSelection(item.id)
            history.save()
            jlog("pick.selected", data: ["id": item.id])

            executeAction(for: item)

        case .cancelled:
            break

    private func executeAction(for item: PickerItem)
        // ... (unchanged) ...

    // MARK: - Async Discovery

    private func discoverAndStream() async

        // NEW: Create shared enricher for this session
        let enricher = WindowEnricher()

        let sources: [PickerSource] = [
            WindowSource(enricher: enricher)
            // Future phases: AppSource(), ZoxideSource(), etc.
        ]

        await withTaskGroup(of: [PickerItem].self) { group in
            for source in sources:
                group.addTask {
                    do:
                        return try await source.discover()
                    catch:
                        jlog("pick.err.source", data: ["source": source.id, "err": "\(error)"])
                        return []
                }

            for await items in group:
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    guard isVisible, let window = window else { return }

                    // NEW: Accumulate items
                    allItems.append(contentsOf: items)

                    // NEW: Sort accumulated items by frecency
                    history.sortByFrecency(&allItems)

                    // Replace all items in state (sorted order)
                    // appendItems dedup by ID handles this correctly
                    window.getState().replaceItems(allItems)
                    // NOTE: If PickerState doesn't have replaceItems(),
                    // alternative: clear + appendItems, preserving query/selection
                }
        }

        await MainActor.run {
            window?.setLoading(false)
        }

    // MARK: - Window Notifications

    @objc private func windowDidResignKey(_ notification: Notification)
        guard !isActivating else { return }
        handleResult(.cancelled)
}
```

**Key decisions:**
- History loaded ONCE in `init()`, not per-show (server is long-lived)
- `allItems` accumulates across source batches for proper global frecency sort
- After each batch, ALL items are re-sorted and replaced (not just appended)
- Selection records to history AND saves to disk immediately
- WindowEnricher created per discovery session (fresh process tree each time)
- `replaceItems` may need to be added to PickerState — it should reset items but preserve current query filter and selection position

---

## Shared Concerns

### PickerState.replaceItems

PickerState needs a new method (or modification to appendItems) to support full replacement while preserving UI state:

```
// In PickerState:
func replaceItems(_ newItems: [PickerItem])
    let currentQuery = query
    let currentSelectionID = selectedItem?.id

    // Replace all items
    items = newItems

    // Re-apply current filter
    if !currentQuery.isEmpty:
        refilter(query: currentQuery)
    else:
        filteredItems = items

    // Restore selection position
    if let prevID = currentSelectionID:
        if let idx = filteredItems.firstIndex(where: { $0.id == prevID }):
            selectedIndex = idx
        // else: selection naturally moves to 0 (top)
```

### SubprocessError enum

```
enum SubprocessError: Error {
    case nonZeroExit
    case notFound
}
```

### State directory helper

```
// Shared path resolution (matches XDG spec from CLAUDE.md)
var stateDir: String {
    if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] {
        return "\(xdg)/thegrid"
    }
    return "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/state/thegrid"
}
```
