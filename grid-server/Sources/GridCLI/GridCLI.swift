import ArgumentParser
import Foundation

@main
struct GridCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thegrid",
        abstract: "Grid window manager CLI",
        subcommands: [
            PingCommand.self,
            FocusCommand.self,
            LayoutCommand.self,
            CellCommand.self,
            WindowCommand.self,
            ResizeCommand.self,
            RecordCommand.self,
            StateCommand.self,
            ConfigCommand.self,
            PickCommand.self,
            TerminalCommand.self,
            ViewCommand.self,
            NotifyCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to server socket")
    var socket: String = "/tmp/grid-server.sock"

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .long, help: "Request timeout in seconds")
    var timeout: Int = 30
}

func makeClient(from options: GlobalOptions) -> RPCClient {
    return RPCClient(socketPath: options.socket, timeout: TimeInterval(options.timeout))
}

func printResult(_ result: [String: Any], json jsonMode: Bool) {
    if jsonMode || !result.isEmpty {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else {
        print("ok")
    }
}

func printOkOrJSON(_ result: [String: Any], json jsonMode: Bool) {
    if jsonMode {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else {
        print("ok")
    }
}
