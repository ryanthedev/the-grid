import ArgumentParser
import Foundation

struct ResizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resize",
        abstract: "Resize operations",
        subcommands: [
            ResizeGrow.self,
            ResizeShrink.self,
            ResizeReset.self,
            ResizeCell.self,
        ]
    )
}

struct ResizeGrow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "grow")
    @Argument(help: "Amount to grow (fraction)")
    var amount: Double = 0.1
    @Flag(name: .long, help: "Resize focused cell boundary")
    var cell: Bool = false
    @Option(name: .long, help: "Direction to grow")
    var direction: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["delta": amount, "cell": cell]
        if let direction = direction {
            params["direction"] = direction
        }

        let result = try client.call("grid.resize.adjust", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct ResizeShrink: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shrink")
    @Argument(help: "Amount to shrink (fraction)")
    var amount: Double = 0.1
    @Flag(name: .long, help: "Resize focused cell boundary")
    var cell: Bool = false
    @Option(name: .long, help: "Direction to shrink")
    var direction: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["delta": -amount, "cell": cell]
        if let direction = direction {
            params["direction"] = direction
        }

        let result = try client.call("grid.resize.adjust", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct ResizeReset: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset")
    @Flag(name: .long, help: "Reset all displays")
    var all: Bool = false
    @Flag(name: .long, help: "Reset cell ratios")
    var cells: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let params: [String: Any] = ["all": all, "cell": cells]
        let result = try client.call("grid.resize.reset", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct ResizeCell: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cell")
    @Argument(help: "Direction of cell boundary to resize")
    var direction: String
    @Argument(help: "Amount to adjust (fraction)")
    var amount: Double = 0.1
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let params: [String: Any] = ["direction": direction, "delta": amount]
        let result = try client.call("grid.resize.cell", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}
