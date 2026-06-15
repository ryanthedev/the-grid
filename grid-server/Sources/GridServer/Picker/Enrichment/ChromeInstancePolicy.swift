//
// ChromeInstancePolicy.swift
// GridServer
//
// Pure decision helpers for distinguishing separate Chrome instances by their
// --user-data-dir. No I/O, no actor isolation, no side effects — unit-testable
// off the sysctl/KERN_PROCARGS2 boundary (that lives in ProcessArgsReader).
//
// Two pure decisions live here:
//   1. Extract the --user-data-dir value from a process argv array.
//   2. Map a user-data-dir to a picker label (basename), suppressing the label
//      for the default (real browser) data dir.
//

import Foundation

enum ChromeInstancePolicy {
    private static let userDataDirFlag = "--user-data-dir"

    // DW-2.1: extract the --user-data-dir value from an argv array.
    // Handles both "--user-data-dir=/path" and "--user-data-dir /path".
    // Returns nil when the flag is absent or carries an empty value.
    static func extractUserDataDir(argv: [String]) -> String? {
        let prefix = userDataDirFlag + "="
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg.hasPrefix(prefix) {
                let value = String(arg.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
            if arg == userDataDirFlag {
                let next = index + 1
                if next < argv.count {
                    let value = argv[next]
                    return value.isEmpty ? nil : value
                }
                return nil
            }
            index += 1
        }
        return nil
    }

    // DW-2.3: map a user-data-dir to a picker label.
    // Returns nil for an absent dir (caller passes nil) or the default Chrome
    // data dir (the real browser); otherwise the dir's basename.
    // defaultDataDir is injected so the comparison is pure and host-stable.
    static func instanceLabel(forUserDataDir dir: String?, defaultDataDir: String) -> String? {
        guard let dir = dir, !dir.isEmpty else {
            return nil
        }
        let normalizedDir = normalize(dir)
        let normalizedDefault = normalize(defaultDataDir)
        if normalizedDir == normalizedDefault {
            return nil
        }
        let basename = (normalizedDir as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    // Resolve the real default Chrome data dir for production callers.
    static func defaultChromeDataDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome"
    }

    // Standardize a path and strip a trailing slash so equivalent paths compare
    // equal (e.g. "/tmp/x/" == "/tmp/x", "~/..." expanded).
    private static func normalize(_ path: String) -> String {
        var standardized = (path as NSString).standardizingPath
        while standardized.count > 1 && standardized.hasSuffix("/") {
            standardized = String(standardized.dropLast())
        }
        return standardized
    }
}
