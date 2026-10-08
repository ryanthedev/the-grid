import ArgumentParser
import Foundation

struct McpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Claude Code integration: MCP server and skill",
        subcommands: [
            McpServeCommand.self,
            McpInstallCommand.self,
            McpUninstallCommand.self,
        ]
    )
}

struct McpServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the MCP server over stdio (used by Claude Code)"
    )

    @Option(name: .long, help: "Path to server socket (default: $GRID_SOCKET or /tmp/grid-server.sock)")
    var socket: String?

    @Option(name: .long, help: "Request timeout in seconds")
    var timeout: Int = 30

    func run() throws {
        let socketPath = socket
            ?? ProcessInfo.processInfo.environment["GRID_SOCKET"]
            ?? "/tmp/grid-server.sock"
        let timeout = TimeInterval(self.timeout)

        // A fresh connection per call survives grid-server restarts for the
        // lifetime of the MCP process.
        let server = MCPServer(version: GridCLIVersion) { method, params in
            let client = RPCClient(socketPath: socketPath, timeout: timeout)
            defer { client.disconnect() }
            return try client.call(method, params: params)
        }
        server.serve()
    }
}

// Where Claude Code keeps user-level config. Mirrors the CLAUDE_CONFIG_DIR
// override Claude Code itself honors.
func claudeConfigDir() -> URL {
    if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
        return URL(fileURLWithPath: dir)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
}

func skillInstallPath() -> URL {
    claudeConfigDir().appendingPathComponent("skills/thegrid/SKILL.md")
}

// Runs `claude ...` through the user's PATH. Returns exit status and combined
// output; -1 when the binary could not be launched at all.
@discardableResult
func runClaude(_ args: [String], quiet: Bool = false) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["claude"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    if !quiet, !output.isEmpty {
        print(output.trimmingCharacters(in: .newlines))
    }
    return (p.terminationStatus, output)
}

func claudeOnPath() -> Bool {
    runClaude(["--version"], quiet: true).status == 0
}

struct McpInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Register the MCP server with Claude Code and install the thegrid skill"
    )

    @Option(name: .long, help: "Claude Code config scope: user, local, or project")
    var scope: String = "user"

    @Option(name: .long, help: "Command Claude Code should launch (default: thegrid, resolved on PATH)")
    var command: String = "thegrid"

    @Flag(name: .long, help: "Only install the skill, skip MCP registration")
    var skillOnly: Bool = false

    func run() throws {
        var failed = false

        if !skillOnly {
            guard claudeOnPath() else {
                throw ValidationError("`claude` not found on PATH. Install Claude Code (https://claude.com/claude-code), then re-run `thegrid mcp install`.")
            }
            // Re-adding an existing name fails, so clear any prior registration
            // (including the old bun-based one) first.
            runClaude(["mcp", "remove", "thegrid", "-s", scope], quiet: true)
            print("Registering MCP server: claude mcp add -s \(scope) thegrid -- \(command) mcp serve")
            let add = runClaude(["mcp", "add", "-s", scope, "thegrid", "--", command, "mcp", "serve"])
            if add.status != 0 {
                print("✗ MCP registration failed")
                failed = true
            } else {
                print("✓ MCP server registered (scope: \(scope))")
            }
        }

        let dest = skillInstallPath()
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EmbeddedSkill.write(to: dest)
        print("✓ Skill installed to \(dest.path)")

        if failed {
            throw ExitCode.failure
        }
        print("")
        print("Restart Claude Code to pick up the new MCP server, then verify with `claude mcp list`.")
    }
}

struct McpUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the MCP server registration and the thegrid skill"
    )

    @Option(name: .long, help: "Claude Code config scope: user, local, or project")
    var scope: String = "user"

    func run() throws {
        if claudeOnPath() {
            let rm = runClaude(["mcp", "remove", "thegrid", "-s", scope])
            print(rm.status == 0 ? "✓ MCP server removed" : "· MCP server was not registered (scope: \(scope))")
        } else {
            print("· `claude` not on PATH, skipping MCP removal")
        }

        let dir = skillInstallPath().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
            print("✓ Skill removed from \(dir.path)")
        } else {
            print("· Skill was not installed")
        }
    }
}
