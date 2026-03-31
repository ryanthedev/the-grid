# Review: Phase 3 - Conversation Detail Pop-Out Window

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-3.1 | Pressing Return on a notification with `detail_cmd` opens a pop-out detail window | SATISFIED | `executeSelectedAction()` at NotificationPanelViewModel.swift:231-233 checks `detailCmd` first and returns `.openDetail(command:title:)`; NotificationPanelWindow.swift:107-112 routes that case to `DetailWindowController.shared.openDetail(_:)` which calls `win.makeKeyAndOrderFront(nil)` at DetailWindow.swift:97. |
| DW-3.2 | iMessage detail window shows last 10 messages with sender direction and timestamps | SATISFIED | `DetailMessageBubble` at DetailViews.swift:110-145 renders `isFromMe` as "you"/"them" with alignment (`.trailing`/`.leading`) and `relativeTime`; `formatRelativeTime()` at DetailViewModel.swift:158-165 converts Unix timestamps to relative strings; `fetch_history()` defaults to `limit=10` at imessage-watch.py:346. |
| DW-3.3 | Running `imessage-watch.py --history <handle>` returns JSON array of messages | SATISFIED | `handle_history_flag()` at imessage-watch.py:384-403 calls `fetch_history()`, `print(json.dumps(history, ...))`, and `sys.exit(0)`; output format is `[{"body": "...", "is_from_me": bool, "timestamp": int}]` as verified at imessage-watch.py:371-375. |
| DW-3.4 | Escape or closing the detail window dismisses it | SATISFIED | `DetailWindow.keyDown` at DetailWindow.swift:14-19 intercepts keyCode 53 (Escape) and calls `dismissDetail()`; `cancelOperation` at DetailWindow.swift:22-24 also calls it; `windowWillClose` delegate method at DetailWindow.swift:114-117 fires on window close button and nilifies viewModel. |
| DW-3.5 | Opening detail for a different notification replaces the current detail content | SATISFIED | `DetailWindowController.openDetail()` at DetailWindow.swift:48-53 checks for existing `viewModel` and window; if present calls `vm.loadDetail(command:title:)` which cancels the previous `loadTask` at DetailViewModel.swift:73-74 before starting a new one. Window title is also updated (`win.title = title` at DetailWindow.swift:50). |

**All requirements met:** YES

## Spec Match

- [x] **File 1 (Notification.swift - detailCmd field):** `detailCmd: String?` at Notification.swift:102; present in `init` parameter at line 128, assigned at line 144. Matches pseudocode exactly.
- [x] **File 2 (NotificationFileWatcher.swift - parse detail_cmd):** `detail_cmd: String?` in `NotificationLineDescriptor` at line 21; `detailCmd: desc.detail_cmd` passed to `GridNotification` init at line 284. Matches pseudocode exactly.
- [x] **File 3 (NotificationPanelViewModel.swift - openDetail action):** `.openDetail(command: String, title: String)` case added at line 22; `executeSelectedAction()` checks detailCmd at lines 231-233, falls through to existing action logic. Matches pseudocode exactly.
- [x] **File 4 (NotificationPanelWindow.swift - route openDetail):** `case .openDetail(let command, let title):` at line 107, delegates to `DetailWindowController.shared.openDetail(...)`. Matches pseudocode exactly.
- [x] **File 5 (DetailWindowController - pseudocode section):** Implemented in DetailWindow.swift lines 27-118. Singleton pattern, reuse-on-reopen, `dismissDetail()`, NSWindowDelegate all present. One deviation from pseudocode: `dismissDetail()` does not destroy the window object (`window` ivar is not set to nil), only hides it and nils `viewModel`. On next `openDetail()` call the guard `if let vm = viewModel, let win = window` will see `viewModel == nil` and fall through to the creation path, creating a new `DetailViewModel` while reusing the existing `DetailWindow`. This is functionally correct and a mild improvement (avoids re-creating the NSWindow unnecessarily) — not a deviation that breaks any DW item.
- [x] **File 6 (DetailViewModel.swift):** All pseudocode sections present: `DetailState` enum, `@Published var state`, `loadTask` cancellation, `runShellCommand()` async continuation, `parseDetailOutput()`, `formatRelativeTime()`. Implementation adds `LocalizedError` conformance on `DetailError` (lines 26-38) beyond spec — benign improvement for error display.
- [x] **File 7 (DetailViews.swift):** All five view structs present: `DetailContentView`, `DetailTitleBar`, `DetailMessageList`, `DetailMessageBubble`, `DetailLoadingView`, `DetailErrorView`. Implementation uses `DetailSpace` and `DetailTypeSize` enums instead of pseudocode's `Space`/`TypeSize` — avoids namespace collision with existing NotificationPanelViews constants. Good defensive choice.
- [x] **File 8 (DetailWindow.swift - NSWindow subclass):** `DetailWindow` with `keyDown` Escape intercept and `cancelOperation` both present at lines 14-24. Matches pseudocode.
- [x] **File 9 (imessage-watch.py - detail_cmd field):** `format_notification()` at line 310-323 adds `detail_cmd` using `os.path.abspath(__file__)`. Matches pseudocode exactly.
- [x] **NotificationStore.swift - upsert preserves detailCmd:** `upsert()` at NotificationStore.swift:170 includes `existing.detailCmd = notification.detailCmd`. This is listed in the changed files and correctly preserves detailCmd on upsert.
- [x] Test coverage: Pseudocode specifies no automated tests. None created. Matches plan strategy.

No unplanned additions.

## Dead Code

None found. All new types are reachable from `DetailWindowController.openDetail()` which is called from `NotificationPanelWindow`. `DetailState.idle` is used as the initial state for `DetailViewModel` and is rendered in `DetailContentView`. `cancelOperation` on `DetailWindow` is an NSResponder override that the AppKit runtime calls — not dead. `DetailError.LocalizedError` conformance is consumed by `error.localizedDescription` at DetailViewModel.swift:88.

One note: `DetailWindowController.dismissDetail()` nils `viewModel` but does not nil `window`. On the next `openDetail()` call, the guard `if let vm = viewModel, let win = window` evaluates to false because `viewModel` is nil, so execution falls through to create a new `DetailViewModel`. The existing `window` ivar still holds the hidden `DetailWindow`. This means the old window is never deallocated for the lifetime of the singleton. Since it is hidden (orderOut), not leaked to the user, and is a singleton controller, this is acceptable — a retained-but-hidden window is a common macOS pattern.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `DetailWindowController` and `DetailViewModel` are `@MainActor` — all access is serialized. `runShellCommand()` bounces to `DispatchQueue.global()` for blocking `Process.waitUntilExit()` then resumes the continuation on the global queue; the `@MainActor` caller (`loadDetail`) awaits the async throw so the state update at line 81 happens back on MainActor. `loadTask?.cancel()` is called on MainActor before launching a new task. Swift cooperative cancellation with `guard !Task.isCancelled` at lines 79, 87 prevents stale results from applying after cancellation. No shared mutable state accessed from multiple actors simultaneously. |
| Error Handling | PASS | Shell failure surfaces as `DetailError.commandFailed` (checked non-zero exit at DetailViewModel.swift:121-125). Non-UTF-8 output throws `DetailError.invalidOutput`. JSON decode failure throws and is caught at line 86 with `state = .error(message: error.localizedDescription)` — user sees the error message. Continuation is always resumed (no path exits without `resume`). `process.run()` throw is caught and forwarded at line 129-131. |
| Resources | PASS | `Pipe` and `Process` are created locally within `DispatchQueue.global().async` closure; `Process` terminates (via `waitUntilExit()`) before the closure exits. `pipe.fileHandleForReading.readDataToEndOfFile()` is called after `waitUntilExit()` so the pipe is fully drained before the continuation resumes. No file descriptor leaks. NSWindow is retained (not leaked) in `self.window`; `isReleasedWhenClosed = false` prevents double-free on close. |
| Boundaries | PASS | Empty message list: `messages.last` returns `nil`, `scrollTo` is not called (DetailViews.swift:98-100 uses `if let last = messages.last`). Single message: renders normally. Large output: `fetch_history` limits to 10 rows via SQL `LIMIT ?`. Negative `interval` in `formatRelativeTime` (future timestamp): falls through to "now" since `interval < 60` is true for negative values — acceptable. `output.data(using: .utf8)` returns nil only for non-UTF-8 strings, which is guarded with `throw DetailError.invalidOutput`. |
| Security | PASS | `detail_cmd` is a string passed to the user's shell unchanged via `["-c", command]` — same pattern used by the existing `executeNotificationAction(.runShellCommand)` at NotificationPanelWindow.swift:136-151. The value originates from the notification pipe, which only the local user writes to (named pipe in `~/.local/state/thegrid/`). No SQL construction in Swift. The Python script uses parameterized queries. The `detail_cmd` value is logged in `jlog("err.notify.detail.load")` but does not contain secrets — it is a script path + handle ID. |

## Defensive Programming: PASS

Crisis triage:
1. **External input validated at boundaries:** JSON from the detail command is decoded through `RawDetailMessage: Codable` — type-checked by `JSONDecoder`. Decode failure propagates to the error state. `is_from_me` is a Bool, `body` is a String, `timestamp` is an Int — all typed. PASS.
2. **Return values checked for all external calls:** `process.run()` throwing is caught. `process.terminationStatus != 0` is checked. `String(data:encoding:)` returning nil is guarded. `output.data(using: .utf8)` returning nil is guarded. `continuation.resume` is called on all paths. PASS.
3. **Error paths tested:** No automated tests per plan strategy. Error state is rendered via `DetailErrorView`. Within scope.
4. **Assertions on critical invariants:** Not applicable — no internal invariants that benefit from assertions beyond what the type system and guard statements already provide.
5. **Resources released on all paths:** `Process` runs to completion before the continuation fires; no dangling handle. `Pipe` is a local — ARC handles it. PASS.

One low-severity note: if the user's `$SHELL` environment variable points to a non-existent path, `process.run()` will throw "No such file or directory" — this is caught and surfaced as a `DetailError` shown in the UI, so the failure is not silent.

## Design Quality: No significant findings

**`DetailWindowController` does not nil `window` on dismiss (LOW):** After `dismissDetail()`, `window` holds a hidden `NSWindow` indefinitely. On the next `openDetail()`, the guard sees `viewModel == nil` and creates a new `DetailViewModel`, then calls `vm.loadDetail()` — but the old `window` is silently discarded (a new `DetailWindow` is allocated at line 75 and stored over `self.window`). The old hidden window is then orphaned with no owner. Since `isReleasedWhenClosed = false`, the old window is retained by `self.window` until the new one overwrites it, at which point ARC releases it. Net effect: one extra `NSWindow` allocation per close-then-reopen cycle, but no leak persists past the second open. The clean fix is to nil `self.window` in `dismissDetail()`. Severity: LOW — no user-visible impact, no leak in steady state.

**`runShellCommand` uses `process.waitUntilExit()` on a background thread (acceptable):** The pseudocode specified this pattern explicitly. Using `waitUntilExit()` on a global queue is correct — it blocks the global queue thread, not the main thread. The Swift concurrency caller is properly suspended via `withCheckedThrowingContinuation`. No threading issue.

**No `theme` update path on re-open:** If the theme changes between window opens, the `DetailViewModel` created during the first open retains the old theme (since `viewModel` is reused on re-open at line 48-53). This is not a DW item and the theme is not expected to change at runtime. Noted, not a blocker.

## Testing: PASS

Per plan strategy: no automated tests for this phase. The implementation is manually testable by pressing Return on an iMessage notification. All state transitions (loading, loaded, error) are reachable. No test file expected or created.

No dirty:clean ratio applicable (no test file).

## Issues

1. **`DetailWindowController` orphans old window on close-then-reopen (LOW)**
   - File: DetailWindow.swift:104-109 (`dismissDetail`)
   - `window` ivar is not set to nil on dismiss. On next `openDetail()`, new `DetailWindow` is allocated and assigned, silently dropping the old hidden reference. ARC will release the old window at that point (not a persistent leak), but this is surprising and wasteful.
   - Fix: Add `self.window = nil` and `self.window?.delegate = nil` in `dismissDetail()`.

**Verdict: PASS**
