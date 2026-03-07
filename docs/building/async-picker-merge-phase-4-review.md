# Review: Phase 4 - CLI RPC + Cleanup

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies "minimal unit tests for core logic only"; Phase 4 is cleanup/deletion with no new core logic requiring tests)

### Section-by-section mapping:

| Pseudocode Section | Implementation | Status |
|---|---|---|
| PickerManager.swift: `pendingRPCContinuation` field | Line 21: `private var pendingRPCContinuation: CheckedContinuation<PickerResult, Never>?` | MATCH |
| PickerManager.swift: `showForRPC()` method | Lines 116-130: async method with `withCheckedContinuation`, calls `show()` | MATCH |
| PickerManager.swift: `handleResult` continuation check | Lines 163-187: captures continuation before `hide()`, resumes after action | MATCH |
| PickerManager.swift: `hide()` continuation cleanup | Lines 152-155: resumes pending continuation with `.cancelled` | MATCH |
| MessageHandler.swift: `pick.show` handler | Lines 1308-1343: registers handler, uses `@MainActor`, returns response | MATCH |
| main.swift: grid-picker kill | Lines 52-57: pkill -9 -f grid-picker, mirrors grid-terminal pattern | MATCH |
| Package.swift: GridPicker removal | No `GridPicker` or `grid-picker` references remain | MATCH |
| main.go: `pickCmd` simplified to RPC-only | Lines 2103-2141: clean `runPick` function, calls `pick.show`, prints result | MATCH |
| main.go: all old functions removed | Grep for 20+ old function names returns zero matches | MATCH |
| main.go: old types removed (PickerItem, PickerResult, PickerContext) | No matches found | MATCH |
| main.go: `pickWindowCmd` removed | No matches found | MATCH |
| main.go: `--only`/`--exclude` flags removed | No matches found | MATCH |
| main.go: shouldSkipMutex updated | `thegrid pick` present, `thegrid pick window` absent | MATCH |
| main.go: unused imports removed | No `crypto/sha256`, `encoding/hex`, `net`, `regexp`, `sort`, or `sources` imports | MATCH |
| main.go: `enrichers` import kept | Line 35: import present, used at line 1578 by edit command | MATCH |
| config/types.go: `PickerPath` removed | No `PickerPath` in any config file | MATCH |
| config/config.go: `PickerPath` expansion removed | `ExpandPaths()` at lines 377-384 only expands `Recording.OutputDir`, `ZoxidePath`, `Chrome.StateFile` | MATCH |
| config/config_test.go: `PickerPath` test removed | No `PickerPath` references in test file | MATCH |
| Makefile: all grid-picker references removed | Zero matches for `grid-picker` in Makefile | MATCH |
| Delete GridPicker directory | `Sources/GridPicker/` does not exist | MATCH |
| Delete sources directory | `grid-cli/internal/sources/` does not exist | MATCH |
| Delete picker_history.go | File does not exist | MATCH |
| Delete picker_history_test.go | File does not exist | MATCH |
| Delete picker_test.go | File does not exist | MATCH |
| Keep enrichers package | 10 files intact in `grid-cli/internal/enrichers/` | MATCH |

### Design note alignment:
- Pseudocode: "The server SHOULD still execute the action even for RPC" -- Implementation confirms: `handleResult` calls `executeAction(for:)` before resuming RPC continuation. MATCH.
- Pseudocode: "Action execution stays server-side" -- Implementation: No action execution code in CLI `runPick`. MATCH.

## Dead Code
None found.

- No unused imports in main.go (verified via `go vet` passing clean)
- No commented-out code blocks in modified files
- No unreachable code after early returns
- No debug print statements

## Correctness Verification
| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 9 pseudocode file modifications and 5 file deletions verified. RPC handler works, CLI simplified, cleanup complete. |
| Concurrency | PASS | `CheckedContinuation` resumed exactly once per lifecycle. All PickerManager methods guarded by `dispatchPrecondition(condition: .onQueue(.main))`. RPC handler uses `@MainActor` to dispatch to main thread. `handleResult` captures and nils continuation before calling `hide()`, preventing double-resume. |
| Error Handling | PASS | CLI `runPick` wraps RPC error with `fmt.Errorf("pick failed: %w", err)`. MessageHandler `pick.show` handler: async error paths handled (picker cancellation returns `.cancelled` response, not an error). `main.swift` grid-picker kill uses `try?` to ignore errors (appropriate for cleanup of potentially-absent process). |
| Resource Mgmt | PASS | CLI creates client with `defer c.Close()`. RPC handler Task completes naturally. PickerManager's `discoveryTask` is cancelled in `hide()`. No resource leaks. |
| Boundaries | PASS | `runPick` handles both cancelled (returns nil) and selected (prints id+title) cases. Empty/nil result fields handled with `ok` checks. `showForRPC` handles already-visible case by calling `hide()` first. |
| Security | N/A | No untrusted external input. RPC is local Unix socket. No user-provided data flows to shell/SQL/HTML. |

## Defensive Programming

### Crisis invariants checked:
| Check | Status | Evidence |
|-------|--------|----------|
| No empty catch blocks | PASS | Swift `try?` on process kill is intentional (cleaning up absent process). No empty catch blocks in Go. |
| No executable code in assertions | PASS | `dispatchPrecondition` calls are validation only, no side effects. |
| External input validated | PASS | RPC result from server is validated with type assertions (`ok` pattern) before use in Go CLI. |
| Assertions for bugs only | PASS | `dispatchPrecondition` correctly asserts thread safety invariant (programmer bug if violated, not runtime condition). |

### CheckedContinuation safety (critical):
Three resume paths verified, all mutually exclusive:
1. **User selects** -> `handleResult(.selected)` captures continuation, nils field, calls `hide()` (which sees nil), resumes with result.
2. **User cancels (Esc)** -> `handleResult(.cancelled)` same path.
3. **Focus loss** -> `windowDidResignKey` -> `handleResult(.cancelled)` same path.
4. **Edge case: `hide()` called directly** (e.g., from `showForRPC()` when already visible) -> `hide()` resumes with `.cancelled` and nils field.

No double-resume is possible because `handleResult` atomically captures and nils the continuation before calling `hide()`. All paths are on the main thread (no concurrent access).

## Build Verification
- Swift build: `Build complete! (2.26s)` -- no warnings
- Go build: clean (no output = success)
- Go vet: clean (no output = success)
- Config tests: `ok` (cached)
