import ArgumentParser
import Foundation

struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Window operations",
        subcommands: [
            WindowMove.self,
            WindowSwap.self,
        ]
    )
}

// MARK: - Window Move

struct WindowMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move focused window",
        subcommands: [
            WindowMoveLeft.self,
            WindowMoveRight.self,
            WindowMoveUp.self,
            WindowMoveDown.self,
        ]
    )
}

struct WindowMoveLeft: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "left")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend to adjacent cell")
    var extend: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try windowMove("left", wrap: wrap, extend: extend, globals: globals)
    }
}

struct WindowMoveRight: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "right")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend to adjacent cell")
    var extend: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try windowMove("right", wrap: wrap, extend: extend, globals: globals)
    }
}

struct WindowMoveUp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend to adjacent cell")
    var extend: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try windowMove("up", wrap: wrap, extend: extend, globals: globals)
    }
}

struct WindowMoveDown: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down")
    @Flag(name: .long, inversion: .prefixedNo, help: "Wrap around edges")
    var wrap: Bool = true
    @Flag(name: .long, help: "Extend to adjacent cell")
    var extend: Bool = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        try windowMove("down", wrap: wrap, extend: extend, globals: globals)
    }
}

private func windowMove(
    _ direction: String,
    wrap: Bool,
    extend: Bool,
    globals: GlobalOptions
) throws {
    let client = makeClient(from: globals)
    defer { client.disconnect() }

    let params: [String: Any] = [
        "direction": direction,
        "wrap": wrap,
        "extend": extend,
    ]

    let result = try client.call("grid.window.move", params: params)
    printOkOrJSON(result, json: globals.json)
}

// MARK: - Window Swap

struct WindowSwap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swap",
        abstract: "Swap focused window",
        subcommands: [
            WindowSwapLeft.self,
            WindowSwapRight.self,
            WindowSwapUp.self,
            WindowSwapDown.self,
        ]
    )
}

struct WindowSwapLeft: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "left")
    @OptionGroup var globals: GlobalOptions
    func run() throws { try windowSwap("left", globals: globals) }
}

struct WindowSwapRight: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "right")
    @OptionGroup var globals: GlobalOptions
    func run() throws { try windowSwap("right", globals: globals) }
}

struct WindowSwapUp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up")
    @OptionGroup var globals: GlobalOptions
    func run() throws { try windowSwap("up", globals: globals) }
}

struct WindowSwapDown: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down")
    @OptionGroup var globals: GlobalOptions
    func run() throws { try windowSwap("down", globals: globals) }
}

private func windowSwap(_ direction: String, globals: GlobalOptions) throws {
    let client = makeClient(from: globals)
    defer { client.disconnect() }

    let result = try client.call("grid.window.swap", params: ["direction": direction])
    printOkOrJSON(result, json: globals.json)
}
