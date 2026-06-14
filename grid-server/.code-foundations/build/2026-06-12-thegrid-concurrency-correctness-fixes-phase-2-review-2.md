# Review: Phase 2 - DW-2.3 (#26) Stale-Write Abort (Re-review)

## Executed Results (Step 0)

| Command | Result |
|---------|--------|
| `swift build` | Build complete (1.95s) — no errors, no warnings |
| `swift test` | **165 tests, 0 failures** (2.506s total) |

---

## Requirement Fulfillment

### DW-2.3 (#26)

PREMISE: "apply re-resolves the space id before its write phase (or aborts on mid-apply migration) — no zombie-space write after a space transition. The abort MUST fire in the migration-only case: when the target space of an in-flight apply has been migrated away, even if no other action bumped the generation counter. The nominal case (target space still exists) MUST NOT abort."

EVIDENCE (predicate): `Sources/GridServer/Grid/SpaceMigrationPolicy.swift:87-93`
EVIDENCE (call site): `Sources/GridServer/Grid/GridApply.swift:136`, `286-300`
EVIDENCE (migration path): `Sources/GridServer/Grid/GridReconciler.swift:998-1028`
EVIDENCE (tests): `Tests/GridServerTests/SpaceMigrationPolicyTests.swift:106-133`

**Predicate trace (`shouldAbortStaleWrite`):**

```swift
// SpaceMigrationPolicy.swift:87-93
static func shouldAbortStaleWrite(
    entryGeneration: UInt64,
    currentGeneration: UInt64,
    spaceStillExists: Bool
) -> Bool {
    return !spaceStillExists
}
```

The predicate ignores the generation parameters entirely and returns `true` iff `spaceStillExists == false`. This is the documented design intent (line 82-86): `handleSpaceIDReassigned` migrates without bumping the generation counter, so a generation comparison cannot detect the migration-only case. The space's disappearance is the sole correctness signal.

**Call-site trace in `applyLayoutBody` (GridApply.swift):**

1. Line 136: `let entryGeneration = gridReconciler?.generation` — snapshot taken at entry, before any awaits.
2. Lines 286-300: After AX placements (step 11) but before any GridState writes (step 13), the code re-resolves:
   - `let currentGeneration = reconciler.generation`
   - `let spaceStillExists = await gridState.getSpaceReadOnly(spaceID) != nil`
   - Calls `SpaceMigrationPolicy.shouldAbortStaleWrite(...)` — if true, logs and `return`s, skipping `setCurrentLayout`, `setWindowAssignments`, and `syncBordersForSpace`.
3. Lines 304-313: The write phase (GridState mutations) is only reached when `shouldAbortStaleWrite` returns false.

**Migration-only case trace:**

- `handleSpaceIDReassigned` (GridReconciler.swift:998-1028) calls `gridState.migrateSpace(from: oldSpaceID, to: newSpaceID)` — this removes the old space key from GridState. It does NOT call `generationCounter.bump()` anywhere in its body.
- After migration: `entryGeneration == currentGeneration` (no bump), but `getSpaceReadOnly(spaceID)` returns nil (space was renamed away).
- `shouldAbortStaleWrite(entryGeneration: X, currentGeneration: X, spaceStillExists: false)` → `!false` = `true` → abort fires.
- Regression test `test_DW_2_3_abort_when_space_gone_even_if_generation_unchanged` at line 123 exercises exactly this path with equal generations and `spaceStillExists: false`, asserting `true`. **PASSED.**

**Nominal case trace:**

- Space still present: `getSpaceReadOnly(spaceID)` returns non-nil → `spaceStillExists = true`.
- `shouldAbortStaleWrite(entryGeneration: X, currentGeneration: Y, spaceStillExists: true)` → `!true` = `false` → no abort.
- Test `test_DW_2_3_no_abort_when_space_exists_and_generation_unchanged` at line 129 exercises this with equal generations and `spaceStillExists: true`, asserting `false`. **PASSED.**
- Test `test_DW_2_3_no_abort_when_space_still_exists` at line 112 exercises it with a different generation (`5` vs `7`) and `spaceStillExists: true`, asserting `false`. **PASSED.**

TRACE:

- **Migration-only zombie-write case:** `applyLayoutBody` enters with `entryGeneration = G`. `handleSpaceIDReassigned` fires concurrently, migrates oldSpaceID → newSpaceID without bumping generation. At pre-write gate: `currentGeneration = G` (unchanged), `getSpaceReadOnly(oldSpaceID)` = nil. `shouldAbortStaleWrite(G, G, false)` = `true`. Body returns before line 304. No GridState mutation. **Abort fires correctly.**

- **Nominal case:** `applyLayoutBody` enters, space survives all awaits. At pre-write gate: `getSpaceReadOnly(spaceID)` ≠ nil. `shouldAbortStaleWrite(_, _, true)` = `false`. Execution continues to steps 13–14: `setCurrentLayout`, `setWindowAssignments`, `syncBordersForSpace` all execute. **No false abort.**

VERDICT: **PASS**

---

## Test-DW Coverage

All four critical DW-2.3 cases have dedicated automated tests in `SpaceMigrationPolicyTests`:

| Test | Case Covered | Result |
|------|-------------|--------|
| `test_DW_2_3_abort_when_generation_changed_and_space_gone` (line 106) | generation advanced AND space gone | PASS |
| `test_DW_2_3_no_abort_when_space_still_exists` (line 112) | generation advanced, space present | PASS |
| `test_DW_2_3_abort_when_space_gone_even_if_generation_unchanged` (line 123) | **migration-only case** — equal generations, space gone | PASS |
| `test_DW_2_3_no_abort_when_space_exists_and_generation_unchanged` (line 129) | nominal case — equal generations, space present | PASS |

The migration-only regression test (line 123) is the critical discriminator. Under the buggy predicate (checking `entryGeneration != currentGeneration || !spaceStillExists`), equal-generation + space-gone would return `false` (no abort), resurrecting the zombie. Under the fixed predicate (`!spaceStillExists`), it returns `true`. The test asserts `true` and **passes**.

- [x] All DW-2.3 cases have corresponding automated tests that ran in Step 0
- [x] The migration-only path is explicitly covered and would fail under the pre-fix logic
- [x] The nominal path is explicitly covered and does not over-abort

---

## Dead Code

`entryGeneration` and `currentGeneration` are passed to `shouldAbortStaleWrite` but the predicate ignores them (documented: "retained for diagnostics at the call site"). The call site logs both values in the `warn.layout.stale_space` event (GridApply.swift:293-299). No unreachable code. The generation snapshot at line 136 is still meaningful for the log payload even though it does not influence the abort decision. This is not dead code — it is diagnostic instrumentation.

No dead code found.

---

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | The pre-write gate re-fetches `spaceStillExists` with `await gridState.getSpaceReadOnly(spaceID)` after all AX placements complete. The gate is positioned between the last await (step 11, applyPlacementsViaAX) and the first GridState write (step 13). `handleSpaceIDReassigned` bypasses the suppression guard (GridReconciler.swift:488-495), so it can execute concurrently during the awaits in `applyLayoutBody` — the gate correctly catches this. |
| Error Handling | PASS | `shouldAbortStaleWrite` is a pure bool predicate; no I/O. The call site handles both outcomes. Throwing path in `applyLayoutBody` still unsuppresses and drains the event queue via `executeAction`'s catch block (GridReconciler.swift:156-170). |
| Resources | N/A | No file handles, connections, or locks in this predicate path. |
| Boundaries | PASS | `entryGeneration` is an `Optional<UInt64>` — the guard `if let entryGeneration, let reconciler` (GridApply.swift:286) correctly handles the nil case (reconciler was never set) by skipping the abort check entirely, which is safe (no write guard = conservative, not dangerous). |
| Security | N/A | No untrusted input. Space IDs are internal strings from the OS. |

---

## Notes (non-blocking)

1. The generation parameters to `shouldAbortStaleWrite` are currently unused in the predicate body. The comment at line 82-86 documents this intentionally. Should a future caller need generation-gating for a non-migration case, the signature already supports it without an API change.

2. `handleSpaceIDReassigned` deliberately does not bump `generationCounter` (confirmed by reading GridReconciler.swift:998-1028 — no call to `generationCounter.bump()`, `executeAction`, `beginAction`, or `endAction`). The invariant relied upon by the predicate design is structurally enforced by the reconciler's architecture, not by a comment alone — correct.

---

VERDICT: **PASS**
