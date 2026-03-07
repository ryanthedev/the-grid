import ArgumentParser
import Foundation

struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record screen capture"
    )

    @Argument(help: "Target type (cell, display, all)")
    var target: String = "cell"

    @Argument(help: "Target ID")
    var id: String?

    @Option(name: [.short, .long], help: "Duration in seconds")
    var duration: Int = 5

    @Option(name: [.short, .long], help: "Output file path")
    var output: String?

    @Option(name: [.short, .long], help: "Output format (gif, mp4, mov)")
    var format: String = "gif"

    @Option(name: .long, help: "Frames per second (0 = auto)")
    var fps: Int = 0

    @Option(name: [.short, .long], help: "Output width in pixels (0 = auto)")
    var width: Int = 0

    @Option(name: [.short, .long], help: "Quality (low, medium, high)")
    var quality: String = "medium"

    @Option(name: .long, help: "Countdown seconds before recording")
    var countdown: Int = 3

    @Flag(name: .long, help: "Show cursor in recording")
    var cursor: Bool = false

    @Flag(name: .long, help: "Open output file after recording")
    var open: Bool = false

    @Flag(name: .long, help: "Follow focus during recording")
    var follow: Bool = false

    @OptionGroup var globals: GlobalOptions

    func run() throws {
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = [
            "target": target,
            "duration": duration,
            "format": format,
            "fps": fps,
            "width": width,
            "quality": quality,
            "countdown": countdown,
            "cursor": cursor,
            "open": open,
            "follow": follow,
        ]
        if let id = id {
            params["id"] = id
        }
        if let output = output {
            params["output"] = output
        }

        let result = try client.call("grid.record.start", params: params)
        printResult(result, json: globals.json)
    }
}
