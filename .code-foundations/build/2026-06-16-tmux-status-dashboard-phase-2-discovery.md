# Discovery + Design: Phase 2 - Model + watcher + config

## Files Found

- `grid-notify/Sources/GridNotify/AnimationConfig.swift` — watcher pattern to mirror (AnimationConfigWatcher)
- `grid-notify/Sources/GridNotify/NotifyConfig.swift` — YAML config pattern; add tmux: block here
- `grid-notify/Sources/GridNotify/Notification.swift` — Codable model conventions (custom enum decode)
- `grid-notify/Sources/GridNotify/XDG.swift` — XDG.stateHome/configHome path helpers
- `grid-notify/Sources/GridNotify/JSONLogger.swift` — jlog() convenience wrapper
- `grid-notify/Tests/GridNotifyTests/NotificationStoreTests.swift` — test style reference (XCTest, async, temp files)
- `grid-notify/Package.swift` — macOS 13+, Yams dependency, single executableTarget

Files to CREATE:
- `grid-notify/Sources/GridNotify/TmuxStatusModel.swift`
- `grid-notify/Sources/GridNotify/TmuxStatusWatcher.swift`
- `grid-notify/Tests/GridNotifyTests/TmuxStatusTests.swift`

Files to MODIFY:
- `grid-notify/Sources/GridNotify/NotifyConfig.swift` — add Tmux struct + YAML parsing

## Current State

No TmuxStatus* files exist. NotifyConfig.swift has no tmux: block. AnimationConfigWatcher is a
clean DispatchSource-based watcher that handles O_EVTONLY, .write/.delete/.rename, retry on
missing file, and callback on MainActor — the exact pattern to replicate.

The JSONLogger uses `jlog("event.name", data: [...])` throughout. NSColor is available (macOS target).

The test fixture at `~/.local/state/thegrid/tmux-status.json` has 11 real sessions and all five
statusKind values in the wild.

## Gaps

None structural. One clarification needed: NSColor is in AppKit, which is available on macOS.
The Package.swift does not explicitly import AppKit but the target is macOS 13+ and the main
executable uses AppKit (AppDelegate, NSWindow, etc.) so NSColor is available. However, in the
TEST target, AppKit types should work since the test target links against the main module.

Observation: The plan says "an NSColor mapping" — I'll expose a computed `color: NSColor` on
TmuxStatusKind since the view (P3) will use it directly. This is consistent with the module
being consumed by SwiftUI on macOS (NSColor ↔ Color bridge is trivial).

## Code Standards

From CLAUDE.md and code-standards.md (project conventions applied):
- No inline trailing comments; comments on own line above the code
- `[weak self]` + `guard let self else { return }` in escaping closures
- `jlog` / JSONLogger — never print()
- Per-module Error/LocalizedError enums if errors are needed
- PascalCase.swift matching primary type
- DispatchSource (not actors) for file watching in grid-notify
- macOS 13+ target; AppKit + SwiftUI available

## Test Infrastructure

XCTest, async/await. Temp paths via NSTemporaryDirectory() + UUID. No mocks — tests use real
temp files. The NotificationStoreTests style is the reference: sync create, async operations,
cleanup in defer blocks.

For the watcher integration test: write a file, start watcher, await onChange callback via
XCTestExpectation (timeout ~3s). For atomic rename: write to .tmp, then FileManager.moveItem.

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-2.1 | A schema-valid JSON sample decodes into `TmuxStatusData` with all fields populated | COVERED | `test_DW_2_1_fullSampleDecodesAllFields`, `test_DW_2_1_allStatusKindGlyphsDistinct`, `test_DW_2_1_allStatusKindColorsNonNil` |
| DW-2.2 | Malformed JSON and unknown `statusKind` do not crash; prior value retained; warn/err logged | COVERED | `test_DW_2_2_malformedJSONSkipped`, `test_DW_2_2_unknownStatusKindDecodesToIdle`, `test_DW_2_2_truncatedJSONSkipped` |
| DW-2.3 | Writing the watched file fires `onChange` with the new decoded value (including atomic rename) | COVERED | `test_DW_2_3_writeFiresOnChange`, `test_DW_2_3_atomicRenameFiresOnChange` |
| DW-2.4 | notify.yaml with tmux: block parses into NotifyConfig.tmux; absent block → defaults | COVERED | `test_DW_2_4_tmuxBlockParsesCorrectly`, `test_DW_2_4_absentTmuxBlockUsesDefaults` |

**All items COVERED:** YES

## Design: TmuxStatusWatcher

### Approaches Considered

1. **Mirror AnimationConfigWatcher exactly** — same O_EVTONLY + DispatchSource, serial queue,
   retry-on-missing, handleChange dispatches back to main. Caller owns last-good-value retention.

2. **Watcher owns last-good value** — watcher holds `private var lastGoodData: TmuxStatusData?`
   and only invokes `onChange` when decode succeeds; malformed events are silently swallowed at
   the watcher level with a logged warning. Caller never sees decode failures.

3. **Combine/async stream** — wrap in AsyncStream<TmuxStatusData> so callers use `for await`.
   Requires Swift Concurrency, departs from the DispatchSource pattern.

### Comparison

| Criterion | A: Mirror AnimationConfigWatcher | B: Watcher owns last-good | C: Async stream |
|-----------|----------------------------------|---------------------------|-----------------|
| Interface simplicity | High (same as existing) | High (same surface) | Med (new pattern) |
| Information hiding | Med (caller must retain last-good) | High (decode errors hidden) | Med |
| Caller ease of use | High (familiar) | Higher (never sees error state) | Med |
| Pattern consistency | Excellent | Good | Poor |
| Defensive programming | Shared responsibility | Barricade at watcher boundary | Shared |
| P3/P5 caller complexity | Caller retains last-good in ViewModel | ViewModel simpler | ViewModel changes |

### Choice: B (Watcher owns last-good) with the external interface of A

Rationale: The watcher IS the barricade boundary for external cross-process input. It should
own the "return previous answer on decode failure" strategy — hiding the error recovery inside
the module is exactly information hiding. The callback signature stays `((TmuxStatusData) -> Void)?`
(same as A) so callers are simple; the watcher internally retains `lastKnownGood` and only fires
`onChange` on successful decode. Errors are logged (jlog warn/err) but not propagated to callers.
This is the "deep module" pattern: simple interface, complex internal behavior.

### Depth Check

- Interface methods: 3 (`start()`, `stop()`, `onChange` callback)
- Hidden details: file descriptor management, DispatchSource lifecycle, retry logic, JSON decode,
  last-good retention, decode error logging
- Common case complexity: simple (caller sets onChange and calls start())

## Design: TmuxStatusModel

Single approach — straightforward Codable structs matching the P1 JSON schema. The interesting
design question is the `TmuxStatusKind` enum's custom decode.

**Lenient decode for statusKind:** Custom `init(from:)` that catches unknown strings and maps
to `.idle` rather than throwing — this is the "substitute closest legal value" strategy for an
enum with a stable vocabulary. Implemented as `init(rawValue:) ?? .idle` pattern.

## Design: NotifyConfig.Tmux

Extend `NotifyConfig` with a nested `Tmux` struct (matches the `ScriptEntry` pattern in the
same file). Add `TmuxYAML` private struct for YAML decoding. Validation: interval clamped to
`max(1, configured)` to reject zero/negative values.

## Prerequisites

- [x] Required files exist (or will be created)
- [x] Dependencies available (Yams present, AppKit/Foundation available)
- [x] AnimationConfigWatcher pattern understood
- [x] jlog signature understood (convenience global func in JSONLogger.swift)
- [x] XCTest test style understood

## Recommendation

BUILD — no blockers, no gaps.
