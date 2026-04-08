# Review: Phase 1 - Window lookup by PID

## Verdict: FAIL

---

## Spec Match

Pseudocode defines three sections. Status of each:

| Pseudocode Section | File | Status |
|---|---|---|
| `ProcessTree.swift` — add `parent` dict + `getAncestors(of:maxDepth:)` | `ProcessTree.swift` | MISSING |
| `MessageHandler.swift` — extend `window.find` to accept `pid` param | `MessageHandler.swift` | MISSING |
| `WindowCommand.swift` — add `WindowFind` subcommand | `WindowCommand.swift` | MISSING |

All three pseudocode sections are unimplemented. The files exist from before this phase but contain no changes from the implementation step.

Evidence:
- `ProcessTree.swift` (92 lines): only `children: [pid_t: [pid_t]]` and `getDescendants`. No `parent` field, no `getAncestors` method.
- `MessageHandler.swift` lines 223–257: `window.find` guard at line 233 still reads `"At least one of appName or title required"`. No `pidFilter` extraction, no `ProcessTree.build()` call, no ancestor walk.
- `WindowCommand.swift` lines 1–147: `WindowCommand.configuration.subcommands` lists only `[WindowMove.self, WindowSwap.self]`. No `WindowFind` struct anywhere in the file.

Test coverage: Plan specifies "None (manual)". No tests written — matches plan.

Unplanned additions: None.

---

## Dead Code

None found. No new code was introduced.

---

## Correctness Verification

All dimensions are N/A or FAIL because the implementation is absent.

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | FAIL | Three requirements from plan (find by PID, error on not-found, build passes) — two not met. Build passes only because no new code exists. |
| Concurrency | N/A | No new async code introduced. |
| Error Handling | N/A | No new handlers introduced. |
| Resource Mgmt | N/A | No new resources acquired. |
| Boundaries | N/A | No new input processing. |
| Security | N/A | No new untrusted input paths. |

---

## Defensive Programming

No new code to audit.

---

## Done-When Criteria (explicit verification)

- [ ] FAIL — `thegrid window find --pid <PID>` returns the window ID for the process (JSON output): command does not exist; `WindowFind` not in `WindowCommand.subcommands`.
- [ ] FAIL — Returns error/empty if no window found for that PID: not-found path not implemented (handler does not accept `pid` param at all).
- [x] PASS — Build passes: `swift build` completes clean with no errors (8.05s). However this is vacuous — the build passes because the implementation was never added, not because new code compiles correctly.

---

## Issues

1. `getAncestors` method missing from ProcessTree
   - File: `grid-server/Sources/GridServer/Picker/Enrichment/ProcessTree.swift`
   - Fix: Add `private var parent: [pid_t: pid_t] = [:]`, populate it in `build()` alongside `children`, and implement `getAncestors(of:maxDepth:) -> [pid_t]` per pseudocode lines 70–85.

2. `window.find` handler not extended for `pid` param
   - File: `grid-server/Sources/GridServer/MessageHandler.swift:223`
   - Fix: Extract `pidFilter = params["pid"]?.value as? Int`, update the guard to allow `pid` as a third valid param, add the PID branch (build ProcessTree, call `getAncestors`, build `ancestorSet`, iterate windows) per pseudocode lines 101–119.

3. `WindowFind` subcommand missing from WindowCommand
   - File: `grid-server/Sources/GridCLI/WindowCommand.swift:8`
   - Fix: Add `WindowFind.self` to `subcommands`, implement `struct WindowFind: ParsableCommand` with `--pid` option per pseudocode lines 127–148.
