import ArgumentParser
import Foundation

struct InputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Synthesize mouse and keyboard input (coordinates are global points, top-left origin)",
        subcommands: [
            InputPosition.self,
            InputMove.self,
            InputClick.self,
            InputDrag.self,
            InputScroll.self,
            InputType.self,
            InputKey.self,
        ]
    )
}

struct InputPosition: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "position", abstract: "Print the mouse position")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("input.mouse.position")
        if globals.json {
            printResult(result, json: true)
        } else {
            print("\(Int(result["x"] as? Double ?? 0)) \(Int(result["y"] as? Double ?? 0))")
        }
    }
}

struct InputMove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move the mouse to X Y")
    @Argument var x: Double
    @Argument var y: Double
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("input.mouse.move", params: ["x": x, "y": y]), json: globals.json)
    }
}

struct InputClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click at X Y (or at the current position)")
    @Argument var x: Double?
    @Argument var y: Double?
    @Option(name: .long, help: "left, right, or middle")
    var button: String = "left"
    @Option(name: .long, help: "Click count (2 for double-click)")
    var count: Int = 1
    @Option(name: .long, help: "Held modifiers, e.g. cmd+shift")
    var modifiers: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params: [String: Any] = ["button": button, "count": count]
        if let x, let y {
            params["x"] = x
            params["y"] = y
        }
        if let modifiers { params["modifiers"] = modifiers }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("input.mouse.click", params: params), json: globals.json)
    }
}

struct InputDrag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drag", abstract: "Drag from X1 Y1 to X2 Y2")
    @Argument var fromX: Double
    @Argument var fromY: Double
    @Argument var toX: Double
    @Argument var toY: Double
    @Option(name: .long, help: "left, right, or middle")
    var button: String = "left"
    @Option(name: .long, help: "Intermediate drag steps")
    var steps: Int = 12
    @Option(name: .long, help: "Held modifiers, e.g. cmd+shift")
    var modifiers: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params: [String: Any] = ["fromX": fromX, "fromY": fromY, "toX": toX, "toY": toY, "button": button, "steps": steps]
        if let modifiers { params["modifiers"] = modifiers }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("input.mouse.drag", params: params), json: globals.json)
    }
}

struct InputScroll: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll by DX DY pixels (positive DY scrolls content up)")
    @Argument var dx: Int
    @Argument var dy: Int
    @Option(name: .long, help: "Scroll at this X (with --y)")
    var x: Double?
    @Option(name: .long, help: "Scroll at this Y (with --x)")
    var y: Double?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params: [String: Any] = ["dx": dx, "dy": dy]
        if let x, let y {
            params["x"] = x
            params["y"] = y
        }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("input.mouse.scroll", params: params), json: globals.json)
    }
}

struct InputType: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type literal text (never triggers shortcuts)")
    @Argument var text: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("input.key.type", params: ["text": text]), json: globals.json)
    }
}

struct InputKey: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press a key or chord, e.g. enter, cmd+s, ctrl+shift+tab")
    @Argument var key: String
    @Option(name: .long, help: "Repeat count")
    var count: Int = 1
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("input.key.press", params: ["key": key, "count": count]), json: globals.json)
    }
}
