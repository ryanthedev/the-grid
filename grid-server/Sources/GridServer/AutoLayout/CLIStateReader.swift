import Foundation

struct CLISpaceState: Decodable {
    let spaceId: String
    let currentLayoutId: String

    enum CodingKeys: String, CodingKey {
        case spaceId = "spaceId"
        case currentLayoutId = "currentLayoutId"
    }
}

struct CLIState: Decodable {
    let version: Int
    let spaces: [String: CLISpaceState]
}

class CLIStateReader {
    static let shared = CLIStateReader()
    private let path: String

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.path = "\(home)/.local/state/thegrid/state.json"
    }

    func hasLayout(spaceID: String) -> Bool {
        guard let state = loadState() else { return false }
        return state.spaces[spaceID]?.currentLayoutId.isEmpty == false
    }

    private func loadState() -> CLIState? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(CLIState.self, from: data)
    }
}
