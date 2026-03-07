import ArgumentParser
import Foundation

struct PickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick",
        abstract: "Show the picker"
    )

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        let result = try client.call("pick.show")

        if let cancelled = result["cancelled"] as? Bool, cancelled {
            // Picker was cancelled, exit silently
            return
        }

        if globals.json {
            printResult(result, json: true)
        } else if let selected = result["selected"] as? [String: Any] {
            let id = selected["id"] ?? ""
            let title = selected["title"] ?? ""
            print("\(id)\t\(title)")
        }
    }
}
