//
// ProcessTree.swift
// GridServer
//
// Builds a process tree from `ps -eo pid,ppid` and provides depth-limited
// descendant and ancestor lookup. Cached per discovery session.
// ALL subprocess calls run on DispatchQueue.global(), NOT the cooperative pool.
//

import Foundation

/// Process tree: bidirectional PID lookup (parent->children and child->parent)
class ProcessTree {
    // parent PID -> [child PIDs]
    private var children: [pid_t: [pid_t]] = [:]
    // child PID -> parent PID
    private var parent: [pid_t: pid_t] = [:]

    // MARK: - Factory

    /// Build tree by running `ps -eo pid,ppid` on DispatchQueue.global().
    /// Bridge to async via withCheckedThrowingContinuation.
    /// Returns empty tree on error (non-fatal).
    static func build() async -> ProcessTree {
        let tree = ProcessTree()

        let output: String
        do {
            output = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/ps")
                    process.arguments = ["-eo", "pid,ppid"]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice

                    do {
                        try process.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        let out = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: out)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            jlog("proc.tree.err", data: ["err": "\(error)"])
            return tree
        }

        // Parse output — skip header line
        let lines = output.split(separator: "\n").dropFirst()
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            guard let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            tree.children[ppid, default: []].append(pid)
            tree.parent[pid] = ppid
        }

        return tree
    }

    // MARK: - Descendant Lookup

    /// BFS up to maxDepth levels. Returns flat array of all descendant PIDs.
    func getDescendants(of parentPID: pid_t, maxDepth: Int) -> [pid_t] {
        guard maxDepth > 0 else { return [] }

        var result: [pid_t] = []
        // BFS queue: (pid, depth-so-far)
        var queue: [(pid: pid_t, depth: Int)] = [(parentPID, 0)]
        var head = 0

        while head < queue.count {
            let (current, depth) = queue[head]
            head += 1

            guard depth < maxDepth else { continue }

            let kids = children[current] ?? []
            result.append(contentsOf: kids)
            for kid in kids {
                queue.append((kid, depth + 1))
            }
        }

        return result
    }

    // MARK: - Ancestor Lookup

    /// Walks upward from targetPID, returning up to maxDepth ancestor PIDs.
    /// Stops early if parent is unknown (reached root or stale PID).
    /// Caller checks whether any known window PID appears in the returned list.
    func getAncestors(of targetPID: pid_t, maxDepth: Int) -> [pid_t] {
        guard maxDepth > 0 else { return [] }

        var result: [pid_t] = []
        var current = targetPID
        var steps = 0

        while steps < maxDepth {
            guard let ppid = parent[current] else { break }
            result.append(ppid)
            current = ppid
            steps += 1
        }

        return result
    }
}
