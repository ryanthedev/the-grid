//
// CommandExecutor.swift
// GridServer
//
// Phase 1 serialization seam (Approach B). A single serial executor consumes
// commands one-at-a-time so that one command body runs end-to-end before the
// next begins. MessageHandler and BFDManager submit() here instead of spawning
// a Task { await router.dispatch(...) } per request/keypress.
//
// Why not a bare actor whose submit() does `await router.dispatch()`?
// Actor reentrancy: the actor releases isolation at every inner await, so a
// second submit() could begin while the first is suspended — defeating the
// serialization guarantee. Instead, submit() enqueues onto an AsyncStream and a
// SINGLE long-lived consumer task pulls one item, runs the command body to
// completion, resumes the waiter, then pulls the next. This guarantees FIFO
// order and inflight <= 1.
//

import Foundation

// The work the executor serializes. GridCommandRouter conforms via dispatch().
// Kept minimal so the executor has a fakeable dependency seam for tests.
protocol CommandRunning: AnyObject {
    func run(_ command: String) async -> CommandResult
}

// Serial command executor. One command body runs at a time, in submission order.
final class CommandExecutor {

    // A queued submission: the command string and the continuation to resume
    // with its result once the body completes.
    private struct Item {
        let command: String
        let continuation: CheckedContinuation<CommandResult, Never>
    }

    private let runner: CommandRunning
    private let stream: AsyncStream<Item>
    private let yield: AsyncStream<Item>.Continuation

    // Number of command bodies currently executing. The serial consumer keeps
    // this at most 1; it is logged on each exec for the DW-1.1 inflight check.
    private var inflight: Int = 0

    init(runner: CommandRunning) {
        self.runner = runner
        var continuation: AsyncStream<Item>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.yield = continuation
        startConsumer()
    }

    // Submit a command for serialized execution. Suspends until the command body
    // (router.dispatch) has run to completion, returning its result. Submission
    // order is preserved: AsyncStream delivers items to the single consumer FIFO.
    func submit(_ command: String) async -> CommandResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            jlog("cmd.submit", data: ["cmd": command])
            yield.yield(Item(command: command, continuation: continuation))
        }
    }

    // Single consumer task: drains the stream one item at a time. The `for await`
    // loop does not advance to the next item until the current body returns, so
    // exactly one command runs end-to-end at a time.
    private func startConsumer() {
        let stream = self.stream
        let runner = self.runner
        Task { [weak self] in
            for await item in stream {
                self?.inflight += 1
                let inflightNow = self?.inflight ?? 1
                jlog("cmd.exec", data: ["cmd": item.command, "inflight": inflightNow])

                let result = await runner.run(item.command)

                self?.inflight -= 1
                item.continuation.resume(returning: result)
            }
        }
    }
}

// Adapt GridCommandRouter to the executor's command-running seam.
extension GridCommandRouter: CommandRunning {
    func run(_ command: String) async -> CommandResult {
        await dispatch(command)
    }
}
