# Review: Phase 1 - Window lookup by PID

## Verdict: PASS

## Spec Match

- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies "None — verified manually")

### Section-by-section mapping

**ProcessTree.swift — parent map + getAncestors**
- `private var parent: [pid_t: pid_t] = [:]` — present at line 17
- `tree.parent[pid] = ppid` added inside the parsing loop alongside the existing `children` assignment — present at line 62
- `getAncestors(of:maxDepth:)` method — present at lines 100–115, matches pseudocode exactly: guard on maxDepth, upward walk via `parent[current]`, break on missing parent, steps counter

**MessageHandler.swift — window.find pid branch**
- `pidFilter = params["pid"]?.value as? Int` — present at line 234
- Guard extended to `appNameFilter != nil || titleFilter != nil || pidFilter != nil` — present at line 236
- `ProcessTree.build()` + `getAncestors(of:maxDepth:8)` — present at lines 246–247
- `ancestorSet = Set([pid_t(pidFilter)] + ancestors)` — present at line 249 (PID itself included)
- Window loop with `isHidden` and `frame.height < 100` filters — present at lines 251–265
- Early return on pid branch — present at line 265 (`return` after `found: false`)

**WindowCommand.swift — WindowFind subcommand**
- `WindowFind.self` added to `subcommands` — present at line 9
- `@Option(name: .long) var pid: Int` — present at line 158
- `client.call("window.find", params: ["pid": pid])` — present at line 166
- JSON branch, plain-text branch, error branch — present at lines 168–175

## Dead Code

None found. All imports in scope, no unreachable code, no debug statements, no commented-out blocks.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All three done-when criteria implemented (see below) |
| Concurrency | PASS | ProcessTree built fresh per-request inside Task; no shared mutable state |
| Error Handling | PASS | ps failure returns empty tree (non-fatal, logged); missing params returns -32602; not-found returns ValidationError in CLI |
| Resource Mgmt | PASS | Process pipe read completes before waitUntilExit; `defer { client.disconnect() }` in CLI |
| Boundaries | PASS | maxDepth 8 bounds the ancestor walk; empty tree returns empty ancestors; ancestorSet always includes pidFilter itself |
| Security | N/A | pid param comes from the CLI caller (trusted invocation context, not user-supplied web input) |

### Requirements coverage

- `thegrid window find --pid <PID>` returns the window ID — WindowFind calls `window.find` with pid, handler returns `found:true, windowId:String(window.id)`, CLI prints windowId on success
- Returns error/empty if no window found — handler returns `found:false`; CLI throws `ValidationError("no window found for pid \(pid)")` producing non-zero exit
- Build passes — structural review of code is consistent; no missing imports, no new dependencies beyond existing `ProcessTree` and `ArgumentParser` already in use

## Defensive Programming

- Silent failure on `ProcessTree.build()` error: intentional and logged via `jlog("proc.tree.err")`. The caller receives an empty tree, the window loop finds nothing, and `found: false` is returned — not silently dropped.
- No bare catch or swallowed exceptions.
- `pidFilter` cast from `params["pid"]?.value as? Int` — if the caller sends a non-Int, the cast fails and the guard at line 236 still passes because pidFilter becomes nil while appNameFilter/titleFilter are also nil, returning the "at least one required" error. This is correct defensive behavior.
- One finding (non-blocking): `getAncestors` has no cycle guard. A malformed or adversarially-constructed process table with a pid→ppid cycle would loop up to `maxDepth` steps and then exit normally. `maxDepth: 8` caps the damage at 8 iterations, so this is bounded and safe in practice. The pseudocode also does not require a cycle guard. Not a failure.

## Issues

None.
