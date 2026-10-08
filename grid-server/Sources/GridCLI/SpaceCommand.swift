import ArgumentParser
import Foundation

struct SpaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "space",
        abstract: "List spaces per display, switch a display's space, pull a window to the current space",
        subcommands: [
            SpaceList.self,
            SpaceSwitch.self,
            SpacePull.self,
        ]
    )
}

struct SpaceList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Print each display's spaces and the windows on them")
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("space.list", params: [:])
        if globals.json {
            printResult(result, json: true)
            return
        }
        for display in result["displays"] as? [[String: Any]] ?? [] {
            let active = display["isActive"] as? Bool == true ? " (active)" : ""
            print("\(display["name"] as? String ?? "display") \(display["uuid"] as? String ?? "")\(active)")
            for space in display["spaces"] as? [[String: Any]] ?? [] {
                let current = space["isCurrent"] as? Bool == true ? " current" : ""
                print("  space \(space["id"] as? String ?? "?") \(space["type"] as? String ?? "?")\(current)")
                for window in space["windows"] as? [[String: Any]] ?? [] {
                    print("    \(window["windowId"] as? String ?? "?")\t\(window["appName"] as? String ?? "")\t\(window["title"] as? String ?? "")")
                }
            }
        }
    }
}

struct SpaceSwitch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "switch", abstract: "Show a space on its display (refused while that display shows a fullscreen space)")
    @Argument(help: "Space id from `space list`")
    var spaceId: String
    @Flag(name: .long, help: "Switch even though the display is showing a fullscreen space")
    var leaveFullscreen = false
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        var params: [String: Any] = ["spaceId": spaceId]
        if leaveFullscreen { params["leaveFullscreen"] = true }
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("space.switch", params: params), json: globals.json)
    }
}

struct SpacePull: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Bring a window to the active display's current space")
    @Argument(help: "Window ID")
    var windowId: String
    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        printOkOrJSON(try client.call("window.pull", params: ["windowId": windowId]), json: globals.json)
    }
}
