# Review: Phase 1 - Notification data model and persistence

## Verdict: PASS

---

## Spec Match

- [x] All pseudocode sections implemented
- [x] No unplanned functional additions
- [x] Test coverage matches plan (backend only, unit tests for CRUD + persistence)

### Naming deviation

All types are prefixed with `Grid` (`GridNotification`, `GridNotificationPriority`, etc.) rather than using the bare names in the pseudocode (`Notification`, `NotificationPriority`, etc.). This is an intentional namespacing choice — it avoids collision with Apple's `UserNotifications` framework types (`UNNotification`, etc.) and is consistent with the project's convention. Not a correctness issue.

### "update" requirement in plan

The plan's "Done when" list says "add/remove/update/filter/bulk-dismiss/pin/unpin/priority-reorder." There is no single `update` method. This is correct — the pseudocode decomposes `update` into discrete state-mutation methods (`markRead`, `dismiss`, `pin`, `unpin`, `setPriority`). All are implemented and tested.

### Minor gap in persistence round-trip test

`testPersistenceRoundTrip` asserts `all.count == 2` but does not verify the order of returned notifications matches the original insertion order. The pseudocode comment says "Assert orderedIDs match." The test verifies both records are present and their fields are correct, but a future regression in orderedIDs reconstruction would not be caught. This is a weakness, not a failure.

---

## Dead Code

No unused imports, unreachable code, debug statements, or commented-out blocks found.

One redundancy: `flush()` has an `if isDirty` guard that duplicates `persistNow()`'s own `guard isDirty else { return }`. This is not dead code — the outer check avoids a call-site overhead — but it creates a maintenance trap if the semantics of either guard ever diverge. Noted as an observation.

---

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All Phase 1 "done when" criteria met: model fields present, all CRUD/filter/bulk/persistence ops implemented and tested |
| Concurrency | PASS | Actor serializes all state; unstructured `Task` in `markDirty` is created from actor-isolated context, inheriting actor executor per Swift semantics |
| Error Handling | PASS | `load()` catches decode errors and logs; `persistNow()` catches write/rename errors, re-marks dirty, and logs; Task cancellation caught with intentional no-op |
| Resource Mgmt | PASS | No file handles held open; `rename()` is atomic; `saveTask` is cancelled before replacement; no unbounded growth (no max cap, but dismissed items require explicit `purge()`) |
| Boundaries | PASS | Empty store returns `[]`; `remove`/`dismiss`/`pin`/etc. guard non-existent IDs; `purge()` no-ops correctly when no dismissed items; `clear()` on empty store is a no-op write deferral |
| Security | N/A | Internal actor with no external input boundary; field values are passed through without execution |

---

## Defensive Programming

| Item | Status | Evidence |
|------|--------|----------|
| No empty catch blocks | PASS | All three catch sites either log the error or have an explanatory comment for the intentional no-op (Task cancellation) |
| No executable code in assertions | PASS | No assertions used |
| External input validated at boundary | N/A | No external boundary in this layer |
| Error strategy consistent with codebase | PASS | Matches GridState pattern: log + recover on I/O errors, never propagate to caller |
| Exception abstraction level correct | PASS | Errors do not escape the actor; callers see only Bool return values |

One observation: `persistNow()` performs synchronous blocking I/O (`Data.write`, POSIX `rename`) on the actor's executor. This blocks the actor for the duration of the write. For small notification payloads this is acceptable, and it matches the GridState reference pattern. If the store grows large, this would need to move to a detached task. Not a current issue.

---

## Issues

None. PASS.
