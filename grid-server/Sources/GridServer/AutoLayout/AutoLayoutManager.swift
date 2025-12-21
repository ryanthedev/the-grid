import Foundation

class AutoLayoutManager {
    static let shared = AutoLayoutManager()

    private var cliPath: String?
    private let queue = DispatchQueue(label: "com.grid.AutoLayout", qos: .userInitiated)
    private let defaultLayout = "two-column-tabs"

    private init() {
        self.cliPath = resolveCLIPath()
    }

    func applyStartupLayoutsAsync() {
        Task {
            let state = StateManager.shared.getState()
            for (_, spaceState) in state.spaces {
                guard spaceState.type == "user" else { continue }

                try? await Task.sleep(nanoseconds: 100_000_000)

                handleSpaceChange(spaceID: spaceState.id, spaceType: spaceState.type)
            }
            await JSONLogger.shared.log("autolayout.startup.done", data: [:])
        }
    }

    func handleSpaceChange(spaceID: UInt64, spaceType: String) {
        guard spaceType == "user" else {
            Task { await JSONLogger.shared.log("autolayout.skip.fullscreen", data: ["sid": spaceID]) }
            return
        }

        if CLIStateReader.shared.hasLayout(spaceID: String(spaceID)) {
            Task { await JSONLogger.shared.log("autolayout.skip.exists", data: ["sid": spaceID]) }
            return
        }

        executeApply(spaceID: spaceID, layoutID: defaultLayout)
    }

    private func executeApply(spaceID: UInt64, layoutID: String) {
        guard let cli = cliPath else {
            Task { await JSONLogger.shared.log("autolayout.error", data: ["sid": spaceID, "err": "CLI not found"]) }
            return
        }

        Task { await JSONLogger.shared.log("autolayout.apply", data: ["sid": spaceID, "layout": layoutID]) }

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["layout", "apply", layoutID, "--space", String(spaceID)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    Task { await JSONLogger.shared.log("autolayout.success", data: ["sid": spaceID]) }
                } else {
                    Task { await JSONLogger.shared.log("autolayout.error", data: ["sid": spaceID, "code": Int(process.terminationStatus)]) }
                }
            } catch {
                Task { await JSONLogger.shared.log("autolayout.error", data: ["sid": spaceID, "err": error.localizedDescription]) }
            }
        }
    }

    private func resolveCLIPath() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["THEGRID_CLI_PATH"],
            "./grid-cli/bin/thegrid",
            "/opt/homebrew/bin/thegrid",
            "/usr/local/bin/thegrid",
        ]

        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
