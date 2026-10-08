import ArgumentParser
import Foundation

struct ClipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip",
        abstract: "Read or replace the clipboard text through the grid server",
        subcommands: [
            ClipRead.self,
            ClipWrite.self,
        ]
    )
}

struct ClipRead: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Print the clipboard's text (refused for concealed or transient contents)")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("clip.read", params: [:])
        if globals.json {
            printResult(result, json: true)
            return
        }
        print(result["text"] as? String ?? "")
        if result["truncated"] as? Bool == true {
            FileHandle.standardError.write(Data("truncated: \(result["returnedBytes"] ?? 0) of \(result["bytes"] ?? 0) bytes\n".utf8))
        }
    }
}

struct ClipWrite: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "write", abstract: "Replace the clipboard with TEXT")
    @Argument(help: "Text to put on the clipboard")
    var text: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("clip.write", params: ["text": text]), json: globals.json)
    }
}
