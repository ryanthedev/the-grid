//
// SSHEnricher.swift
// GridServer
//
// Detects SSH connections in Ghostty windows.
// Builds a PID->isSSH cache from `ps -ax -o pid=,comm=`, then searches
// the process tree (depth 6) for ssh processes. Parses SSH args for user/host.
//

import Foundation

class SSHEnricher {
    // Set of PIDs that are ssh processes (from ps cache)
    private var sshPIDs: Set<pid_t> = []

    // Only Ghostty is supported (matches Go code)
    private let supportedBundleIDs: Set<String> = [
        "com.mitchellh.ghostty"
    ]

    // MARK: - Cache Refresh

    /// Build SSH process cache from `ps -ax -o pid=,comm=`.
    /// Called once per discovery session from WindowEnricher.refreshCaches().
    func refreshCache() async {
        let output = await runProcess("/bin/ps", args: ["-ax", "-o", "pid=,comm="])
        guard let output, !output.isEmpty else {
            sshPIDs = []
            return
        }

        var pids: Set<pid_t> = []
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            guard let pid = pid_t(fields[0]) else { continue }
            let comm = String(fields[1])
            if comm == "ssh" {
                pids.insert(pid)
            }
        }
        sshPIDs = pids
    }

    // MARK: - Enrichment

    func supports(bundleID: String) -> Bool {
        return supportedBundleIDs.contains(bundleID)
    }

    /// Enrich a window PID by finding an ssh process in its descendants.
    func enrich(pid: pid_t, windowTitle: String, tree: ProcessTree) async -> EnrichmentResult? {
        // Search process tree (depth 6: login->shell->bash->zsh->script->ssh)
        let descendants = tree.getDescendants(of: pid, maxDepth: 6)

        var sshPID: pid_t = 0
        for dpid in descendants {
            if sshPIDs.contains(dpid) {
                sshPID = dpid
                break
            }
        }

        guard sshPID != 0 else { return nil }

        // Get SSH command line: `ps -o args= -p {sshPID}`
        let argsOutput = await runProcess("/bin/ps", args: ["-o", "args=", "-p", "\(sshPID)"])
        guard let argsOutput, !argsOutput.isEmpty else { return nil }

        // Parse SSH args for user@host
        guard let (user, host) = Self.parseSSHArgs(argsOutput) else {
            jlog("ssh.parse_err", data: ["args": argsOutput])
            return nil
        }

        // Extract title context (remote cwd/command from window title)
        let (remoteCwd, remoteCommand) = Self.extractTitleContext(windowTitle)

        // Build subtitle from available context
        let subtitle: String
        if !remoteCwd.isEmpty && !remoteCommand.isEmpty {
            subtitle = "\(remoteCwd): \(remoteCommand)"
        } else if !remoteCwd.isEmpty {
            subtitle = remoteCwd
        } else if !remoteCommand.isEmpty {
            subtitle = remoteCommand
        } else {
            subtitle = ""
        }

        return EnrichmentResult(
            title: "\(user)@\(host)",
            subtitle: subtitle,
            stableIDSuffix: "\(user)@\(host)",
            kind: .ssh
        )
    }

    // MARK: - SSH Arg Parsing

    /// Parse SSH command line to extract user and host.
    /// Handles: ssh user@host, ssh -l user host, ssh host (uses current user)
    /// Skips flags with values: -l, -p, -i, -o, -F, -J, -D, -L, -R, -W, -b, -c, -e, -m, -S, -w
    static func parseSSHArgs(_ args: String) -> (user: String, host: String)? {
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

        while i < parts.count {
            let arg = parts[i]

            if arg == "-l" && i + 1 < parts.count {
                extractedUser = parts[i + 1]
                i += 2
                continue
            }

            if flagsWithValues.contains(arg) && i + 1 < parts.count {
                i += 2  // skip flag + value
                continue
            }

            if arg.hasPrefix("-") {
                i += 1
                continue
            }

            positionalArgs.append(arg)
            i += 1
        }

        guard !positionalArgs.isEmpty else { return nil }

        let destination = positionalArgs[0]

        if let atIndex = destination.lastIndex(of: "@") {
            let user = String(destination[..<atIndex])
            let host = String(destination[destination.index(after: atIndex)...])
            guard !host.isEmpty else { return nil }
            return (user, host)
        } else {
            let host = destination
            var user = extractedUser
            if user.isEmpty {
                user = NSUserName()
            }
            guard !host.isEmpty else { return nil }
            return (user, host)
        }
    }

    // MARK: - Title Context Parsing

    /// Parse window title for remote cwd/command.
    /// Format: "~path: command" or "/path: command"
    static func extractTitleContext(_ title: String) -> (cwd: String, command: String) {
        guard let colonRange = title.range(of: ": ") else {
            return ("", "")
        }

        let prefix = String(title[..<colonRange.lowerBound])
        let suffix = String(title[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        if prefix.hasPrefix("~") || prefix.hasPrefix("/") {
            return (prefix, suffix)
        } else if suffix.hasPrefix("~") || suffix.hasPrefix("/") {
            return (suffix, "")
        } else {
            return ("", suffix)
        }
    }
}
