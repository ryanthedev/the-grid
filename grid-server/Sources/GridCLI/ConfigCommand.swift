import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configuration management",
        subcommands: [
            ConfigShow.self,
            ConfigInit.self,
        ]
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.config.show")
        printResult(result, json: globals.json)
    }
}

struct ConfigInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create default configuration file"
    )

    func run() throws {
        // Determine config path using XDG
        let configHome: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = xdg
        } else {
            configHome = NSHomeDirectory() + "/.config"
        }
        let configDir = configHome + "/thegrid"
        let configPath = configDir + "/config.yaml"

        // Check if file exists
        if FileManager.default.fileExists(atPath: configPath) {
            throw ValidationError("Config file already exists at \(configPath)")
        }

        let defaultConfig = """
        # Grid Layout Configuration
        settings:
          defaultStackMode: vertical
          cellPadding: 8
          animationDuration: 0.2
          focusFollowsMouse: false

        layouts:
          - id: two-column
            name: Two Column
            description: Equal two-column split
            grid:
              columns: ["1fr", "1fr"]
              rows: ["1fr"]
            cells:
              - id: left
                column: "1/2"
                row: "1/2"
              - id: right
                column: "2/3"
                row: "1/2"

          - id: main-side
            name: Main + Sidebar
            description: Large main area with sidebar
            grid:
              columns: ["2fr", "1fr"]
              rows: ["1fr"]
            cells:
              - id: main
                column: "1/2"
                row: "1/2"
              - id: side
                column: "2/3"
                row: "1/2"

        spaces:
          "1":
            name: Main
            layouts: [two-column, main-side]
            defaultLayout: two-column
            autoApply: false

        appRules:
          - app: Finder
            float: true
        """

        // Create directory
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Write file
        try defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)

        print("Created config at: \(configPath)")
    }
}
