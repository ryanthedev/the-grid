import ArgumentParser
import Foundation

// Top-level notify command with subcommands for notification management.
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Notification management",
        subcommands: [
            NotifyShow.self,
            NotifyHide.self,
            NotifyToggle.self,
            NotifyPush.self,
            NotifyList.self,
            NotifyDismiss.self,
            NotifyClear.self,
            NotifyCount.self,
            NotifyAssign.self,
            NotifyUnassign.self,
            NotifyInstallHook.self,
        ]
    )
}

// MARK: - Show / Hide / Toggle

struct NotifyShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the notification panel"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Cell ID to assign the panel to for tiling")
    var cell: String?

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        var params: [String: Any] = [:]
        if let cell = cell { params["cell"] = cell }
        let result = try client.call("grid.notify.show", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct NotifyHide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Hide the notification panel"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.hide")
        printOkOrJSON(result, json: globals.json)
    }
}

struct NotifyToggle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Toggle the notification panel"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Cell ID to assign the panel to when showing")
    var cell: String?

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        var params: [String: Any] = [:]
        if let cell = cell { params["cell"] = cell }
        let result = try client.call("grid.notify.toggle", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct NotifyAssign: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assign",
        abstract: "Assign the notification panel to a grid cell for tiling"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Cell ID to assign the panel to")
    var cell: String

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.assign", params: ["cell": cell])
        printOkOrJSON(result, json: globals.json)
    }
}

struct NotifyUnassign: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unassign",
        abstract: "Remove the notification panel from its grid cell"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.unassign")
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Push

struct NotifyPush: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push a new notification"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Notification title")
    var title: String

    @Option(name: .long, help: "Notification body text")
    var body: String?

    @Option(name: .long, help: "Priority: low, normal, high, urgent")
    var priority: String?

    @Option(name: .long, help: "Source label")
    var source: String?

    @Option(name: .long, help: "Action: focus:<wid>, exec:<cmd>, url:<url>")
    var action: String?

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["title": title]
        if let body { params["body"] = body }
        if let priority { params["priority"] = priority }
        if let source { params["source"] = source }
        if let action { params["action"] = action }

        let result = try client.call("grid.notify.push", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - List

struct NotifyList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notifications"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Filter by source")
    var source: String?

    @Option(name: .long, help: "Minimum priority")
    var priority: String?

    @Flag(name: .long, help: "Include dismissed notifications")
    var all: Bool = false

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = [:]
        if let source { params["source"] = source }
        if let priority { params["priority"] = priority }
        if all { params["all"] = true }

        let result = try client.call("grid.notify.list", params: params)
        // The "message" field contains JSON array of notifications
        printResult(result, json: globals.json)
    }
}

// MARK: - Dismiss

struct NotifyDismiss: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Dismiss a notification by ID"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Notification ID to dismiss")
    var id: String

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.dismiss", params: ["id": id])
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Clear

struct NotifyClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Dismiss all active notifications"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Permanently remove dismissed notifications")
    var purge: Bool = false

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        var params: [String: Any] = [:]
        if purge { params["purge"] = true }
        let result = try client.call("grid.notify.clear", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Install Hook

// Installs the Claude Code idle notification hook: writes the shell script to
// ~/.local/share/thegrid/hooks/claude-waiting.sh and wires the Notification/idle_prompt
// entry into ~/.claude/settings.json without destroying existing content.
struct NotifyInstallHook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-hook",
        abstract: "Install Claude Code idle notification hook"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // --- Step 1: Resolve paths ---

        // XDG_DATA_HOME default is ~/.local/share
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? "\(home)/.local/share"
        let hooksDir = "\(dataHome)/thegrid/hooks"
        let scriptPath = "\(hooksDir)/claude-waiting.sh"

        let claudeConfigDir = "\(home)/.claude"
        let settingsPath = "\(claudeConfigDir)/settings.json"

        // Resolve the thegrid binary path at install time so the hook script
        // continues to work even if PATH changes later.
        let thegridBin = resolveThegridBin(home: home)

        // --- Step 2: Write hook script ---

        try FileManager.default.createDirectory(
            atPath: hooksDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let scriptContent = buildHookScript(thegridBin: thegridBin)
        guard let scriptData = scriptContent.data(using: .utf8) else {
            throw ValidationError("Failed to encode hook script as UTF-8")
        }
        FileManager.default.createFile(atPath: scriptPath, contents: scriptData, attributes: nil)

        // Make the script executable (rwxr-xr-x = 0o755)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptPath
        )

        // --- Step 3: Merge settings.json ---

        try mergeSettingsJSON(
            settingsPath: settingsPath,
            claudeConfigDir: claudeConfigDir,
            scriptPath: scriptPath
        )

        print("Installed hook script: \(scriptPath)")
        print("Updated: \(settingsPath)")
        print("Claude Code will notify theGrid when idle.")
    }

    // Resolves the thegrid binary path by running `which thegrid`.
    // Falls back to ~/.local/bin/thegrid if which fails or returns empty.
    private func resolveThegridBin(home: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["thegrid"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !output.isEmpty {
                return output
            }
        } catch {
            // which unavailable — fall through to default
        }

        return "\(home)/.local/bin/thegrid"
    }

    // Builds the hook shell script with the resolved thegrid binary path embedded.
    // The script reads the Claude Code hook JSON from stdin, extracts cwd and tmux
    // metadata, walks the parent PID chain via `thegrid window find --pid`, and
    // pushes a notification to theGrid.
    private func buildHookScript(thegridBin: String) -> String {
        return """
        #!/bin/bash
        # Claude Code idle notification hook for theGrid
        # Installed by: thegrid notify install-hook
        # Fires on Notification/idle_prompt event (Claude finished, waiting for input)

        set -euo pipefail

        THEGRID="\(thegridBin)"

        # Read the hook event JSON from stdin (Claude Code passes it here)
        INPUT=$(cat)

        # Extract cwd from the hook event JSON
        CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

        # Get project directory basename
        if [ -n "$CWD" ]; then
            PROJECT=$(basename "$CWD")
        else
            PROJECT="unknown"
        fi

        # Get tmux session:window if inside tmux
        TMUX_INFO=""
        if [ -n "${TMUX:-}" ]; then
            TMUX_INFO=$(tmux display-message -p '#S:#W' 2>/dev/null || true)
        fi

        # Build notification body
        if [ -n "$TMUX_INFO" ]; then
            BODY="$TMUX_INFO  $PROJECT"
        else
            BODY="$PROJECT"
        fi

        # Walk parent PID chain to find the terminal window.
        # The chain: hook -> claude -> shell -> tmux-client -> shell -> terminal app
        # thegrid window find --pid walks ancestors automatically (server-side)
        SELF_PID=$$
        WID=$("$THEGRID" window find --pid "$SELF_PID" 2>/dev/null || true)

        # Build action: focus the terminal window if found, else no action
        if [ -n "$WID" ]; then
            ACTION="focus:$WID"
        else
            ACTION=""
        fi

        # Push notification to theGrid panel
        NOTIFY_ARGS=("Claude" --body "$BODY" --source "claude-code")
        if [ -n "$ACTION" ]; then
            NOTIFY_ARGS+=(--action "$ACTION")
        fi

        "$THEGRID" notify push "${NOTIFY_ARGS[@]}" 2>/dev/null || true

        exit 0
        """
    }

    // Reads ~/.claude/settings.json (or starts with {}), merges the Notification/idle_prompt
    // hook entry, and writes back. Idempotent: skips if claude-waiting.sh is already present.
    private func mergeSettingsJSON(
        settingsPath: String,
        claudeConfigDir: String,
        scriptPath: String
    ) throws {
        var root: [String: Any]

        if FileManager.default.fileExists(atPath: settingsPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            // Create ~/.claude directory if it doesn't exist
            try FileManager.default.createDirectory(
                atPath: claudeConfigDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            root = [:]
        }

        // Navigate to hooks dict
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Navigate to Notification array
        var notificationHooks = hooks["Notification"] as? [[String: Any]] ?? []

        // Idempotency: skip if a claude-waiting.sh entry already exists
        let alreadyInstalled = notificationHooks.contains { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains("claude-waiting.sh")
            }
        }

        if !alreadyInstalled {
            let newEntry: [String: Any] = [
                "matcher": "idle_prompt",
                "hooks": [
                    [
                        "type": "command",
                        "command": scriptPath
                    ]
                ]
            ]
            notificationHooks.append(newEntry)
        }

        hooks["Notification"] = notificationHooks
        root["hooks"] = hooks

        let serialized = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try serialized.write(to: URL(fileURLWithPath: settingsPath))
    }
}

// MARK: - Count

struct NotifyCount: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count active notifications"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.count")
        // Print just the count number for scripting.
        // If the response is unexpected (not a String), print "0" so callers
        // always receive a numeric string rather than silent empty output.
        if let msg = result["message"] as? String {
            print(msg)
        } else {
            print("0")
        }
    }
}
