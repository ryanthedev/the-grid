import ArgumentParser
import Foundation

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus navigation",
        subcommands: [
            FocusLeft.self,
            FocusRight.self,
            FocusUp.self,
            FocusDown.self,
            FocusNext.self,
            FocusPrev.self,
            FocusCell.self,
        ]
    )
}

// MARK: - Direction commands

struct FocusLeft: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "left")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend selection")
    var extend: Bool = false
    @Flag(name: .long, help: "Move mouse to focused window")
    var mouse: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try focusDirection("left", wrap: wrap, extend: extend, mouse: mouse, globals: globals)
    }
}

struct FocusRight: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "right")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend selection")
    var extend: Bool = false
    @Flag(name: .long, help: "Move mouse to focused window")
    var mouse: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try focusDirection("right", wrap: wrap, extend: extend, mouse: mouse, globals: globals)
    }
}

struct FocusUp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend selection")
    var extend: Bool = false
    @Flag(name: .long, help: "Move mouse to focused window")
    var mouse: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try focusDirection("up", wrap: wrap, extend: extend, mouse: mouse, globals: globals)
    }
}

struct FocusDown: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend selection")
    var extend: Bool = false
    @Flag(name: .long, help: "Move mouse to focused window")
    var mouse: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try focusDirection("down", wrap: wrap, extend: extend, mouse: mouse, globals: globals)
    }
}

private func focusDirection(
    _ direction: String,
    wrap: Bool,
    extend: Bool,
    mouse: Bool,
    globals: GlobalOptions
) throws {
    let client = makeClient(from: globals)
    defer { client.disconnect() }

    var params: [String: Any] = ["direction": direction]
    params["wrap"] = wrap
    params["extend"] = extend
    params["mouse"] = mouse

    let result = try client.call("grid.focus", params: params)
    printOkOrJSON(result, json: globals.json)
}

// MARK: - Cycle commands

struct FocusNext: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "next")
    @Flag(name: .long, help: "Move mouse to focused window")
    var mouse: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["forward": true]
        params["mouse"] = mouse

        let result = try client.call("grid.focus.cycle", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

struct FocusPrev: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prev")
    @Flag(name: .long, help: "Move mouse to focused window")
    var mouse: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["forward": false]
        params["mouse"] = mouse

        let result = try client.call("grid.focus.cycle", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}

// MARK: - Cell focus

struct FocusCell: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cell")
    @Argument(help: "Cell ID to focus")
    var cell: String
    @Option(name: .long, help: "Space ID")
    var space: String?
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["cell": cell]
        if let space = space {
            params["space"] = space
        }

        let result = try client.call("grid.focus.cell", params: params)
        printOkOrJSON(result, json: globals.json)
    }
}
