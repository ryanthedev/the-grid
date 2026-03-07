import ArgumentParser
import Foundation

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Layout management",
        subcommands: [
            LayoutApply.self,
            LayoutList.self,
            LayoutCurrent.self,
            LayoutRefresh.self,
            LayoutCycle.self,
            LayoutEdit.self,
        ]
    )
}

struct LayoutApply: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apply")
    @Argument(help: "Layout ID to apply")
    var layout: String
    @Option(name: .long, help: "Assignment strategy")
    var strategy: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["layout": layout]
        if let strategy = strategy {
            params["strategy"] = strategy
        }

        let result = try client.call("grid.layout.apply", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct LayoutList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.layout.list")
        printResult(result, json: globals.json)
    }
}

struct LayoutCurrent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "current")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.layout.current")
        printResult(result, json: globals.json)
    }
}

struct LayoutRefresh: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh")
    @Option(name: .long, help: "Display ID to refresh")
    var display: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = [:]
        if let display = display {
            params["display"] = display
        }

        let result = try client.call("grid.layout.refresh", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct LayoutCycle: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cycle")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("grid.layout.cycle")
        printOkOrJSON(result, json: globals.json)
    }
}

struct LayoutEdit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a layout definition in $EDITOR"
    )
    @Argument(help: "Layout ID to edit")
    var layout: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        // Step 1: Fetch layout definition
        let getResult = try client.call("grid.layout.get", params: ["layout": layout])
        guard let definition = getResult["definition"] else {
            throw ValidationError("No definition returned for layout '\(layout)'")
        }

        // Step 2: Serialize to pretty JSON and write to temp file
        let jsonData = try JSONSerialization.data(
            withJSONObject: definition,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ValidationError("Failed to serialize layout definition")
        }

        let tempDir = NSTemporaryDirectory()
        let tempFile = (tempDir as NSString).appendingPathComponent("grid-layout-\(layout).json")
        try jsonString.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        // Compute hash of original content
        let originalHash = jsonData.hashValue

        // Step 3: Open $EDITOR
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [editor, tempFile]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ValidationError("Editor exited with status \(process.terminationStatus)")
        }

        // Step 4: Read back and check for changes
        let editedString = try String(contentsOfFile: tempFile, encoding: .utf8)
        let editedData = editedString.data(using: .utf8)!
        if editedData.hashValue == originalHash {
            print("No changes made")
            return
        }

        // Step 5: Parse edited JSON
        guard let edited = try JSONSerialization.jsonObject(with: editedData) as? [String: Any] else {
            throw ValidationError("Edited file is not valid JSON")
        }

        // Step 6: Send update
        let updateResult = try client.call(
            "grid.layout.update",
            params: ["layout": layout, "definition": edited]
        )
        printOkOrJSON(updateResult, json: globals.json)
    }
}
