import ArgumentParser
import Foundation

struct ViewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Open a file in the grid viewer"
    )

    @Argument(help: "File to view (image, GIF, or video)")
    var file: String

    @Flag(name: .long, help: "Open in a new window instead of reusing existing")
    var new: Bool = false

    func run() throws {
        let path = (file as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let resolved = url.standardized.path

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ValidationError("File not found: \(file)")
        }

        guard let viewer = findViewer() else {
            throw ValidationError("grid-viewer not found. Run 'make install-dev' or ensure grid-viewer is in PATH.")
        }

        var args = [resolved]
        if new {
            args.insert("--new", at: 0)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: viewer)
        process.arguments = args
        try process.run()
    }
}

private func findViewer() -> String? {
    // Check ~/.local/bin first (install-dev location)
    let localBin = NSHomeDirectory() + "/.local/bin/grid-viewer"
    if FileManager.default.isExecutableFile(atPath: localBin) {
        return localBin
    }

    // Check PATH
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    task.arguments = ["grid-viewer"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == false ? output : nil
}
