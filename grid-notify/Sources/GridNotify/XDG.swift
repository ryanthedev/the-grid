import Foundation

enum XDG {
    static var configHome: String {
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !env.isEmpty {
            return env
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.config"
    }

    static var configDirs: [String] {
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_DIRS"], !env.isEmpty {
            let dirs = env.split(separator: ":").compactMap { segment -> String? in
                let path = String(segment)
                guard !path.isEmpty, path.hasPrefix("/") else { return nil }
                return path
            }
            if !dirs.isEmpty {
                return dedup(dirs)
            }
        }
        #if os(macOS)
        return ["/etc/xdg", "/opt/homebrew/etc", "/usr/local/etc"]
        #else
        return ["/etc/xdg"]
        #endif
    }

    static var stateHome: String {
        if let env = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !env.isEmpty {
            return env
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state"
    }

    static func findConfigFiles(app: String, filename: String) async -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for dir in configDirs.reversed() {
            let path = "\(dir)/\(app)/\(filename)"
            guard !seen.contains(path) else { continue }
            seen.insert(path)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    paths.append(path)
                }
            } else if let error = checkAccessError(path: path) {
                jlog("cfg.skip", msg: "cannot access file",
                    data: ["path": path, "err": error])
            }
        }

        let userPath = "\(configHome)/\(app)/\(filename)"
        if !seen.contains(userPath) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: userPath, isDirectory: &isDir) {
                if !isDir.boolValue {
                    paths.append(userPath)
                }
            } else if let error = checkAccessError(path: userPath) {
                jlog("cfg.skip", msg: "cannot access file",
                    data: ["path": userPath, "err": error])
            }
        }

        return paths
    }

    private static func checkAccessError(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            _ = try url.checkResourceIsReachable()
            return nil
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return nil
            }
            return error.localizedDescription
        }
    }

    private static func dedup(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}
