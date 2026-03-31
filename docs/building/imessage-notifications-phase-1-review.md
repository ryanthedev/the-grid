# Review: Phase 1 - Upsert + Grouping in NotificationStore

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-1.1 | Pipe payload with `id` field updates existing notification instead of creating new | SATISFIED | NotificationFileWatcher.swift:288-299 — `hasExplicitID` routes to `store.upsert(notification)`; NotificationStore.swift:165 — upsert checks `byID[notification.id]` and updates in place |
| DW-1.2 | Upserted notification body is replaced, TTL is reset, group_count increments | SATISFIED | NotificationStore.swift:167-180 — `existing.body = notification.body`, `existing.ttlResetDate = Date()`, `existing.groupCount += 1`; Notification.swift:154,165 — `lifecyclePhase` and `secondsRemaining` both use `ttlResetDate ?? timestamp` |
| DW-1.3 | Group count displayed next to title (e.g., "Sarah (3)") | SATISFIED | NotificationPanelViews.swift:351-356 — `displayTitle` computed property returns `"\(notification.title) (\(notification.groupCount))"` when `groupCount > 1`; used in all three title branches (MatrixText:368, WaveText:376, Text:383) |
| DW-1.4 | Notifications without explicit `id` still create normally (backward compatible) | SATISFIED | NotificationFileWatcher.swift:273 — `let notificationID = desc.id ?? UUID().uuidString`; line 295 — `else { await store.add(notification) }` when no explicit id |

**All requirements met:** YES

## Spec Match

- [x] Section 1 (GridNotification fields): `groupCount: Int` and `ttlResetDate: Date?` added to Notification.swift:107-110, init defaults at lines 125-126; `lifecyclePhase` and `secondsRemaining` updated to use `ttlResetDate ?? timestamp` at lines 154 and 165
- [x] Section 1 (NotificationStore.upsert): Implemented at NotificationStore.swift:164-186, matches pseudocode exactly including field list (body, ttl, warnBefore, action, priority), ttlResetDate reset, groupCount increment, isDismissed/isRead clear, and add() delegation for new IDs
- [x] Section 2 (NotificationLineDescriptor id field): `let id: String?` added at NotificationFileWatcher.swift:11
- [x] Section 3 (processLine routing): Implemented at NotificationFileWatcher.swift:273-299 — id-based routing to upsert vs add with `hasExplicitID` flag
- [x] Section 4 (displayTitle in NotificationItemView): `displayTitle` computed property at NotificationPanelViews.swift:351-356, used in all three title branches
- [x] Section 5 (tests): All 5 specified tests implemented in NotificationStoreTests.swift:107-203 — testUpsertUpdatesExisting, testUpsertResetsTTL, testUpsertInsertsWhenNew, testUpsertClearsDismissed, testAddWithoutIdCreatesDistinctEntries

No unplanned additions detected.

Test coverage: backend unit tests only, matches plan's "Backend only" level.

## Dead Code

None found. No unused imports, no unreachable code after early returns, no debug statements, no commented-out blocks.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `NotificationStore` is an actor — upsert is a single atomic method with no TOCTOU gap. NotificationFileWatcher uses a private serial `DispatchQueue` to protect fd, readSource, fsSource, and lineBuffer. Task closures in processLine capture `store` and `callback` explicitly (lines 289-290) before crossing actor boundaries. |
| Error Handling | PASS | processLine wraps decode in do/catch and logs with `jlog` on failure (line 301-305); silent skip is intentional for malformed input per spec. openAndWatch handles open() failure with 5s retry (line 115). fstat failure tears down and retries (line 131). |
| Resources | PASS | tearDown() at line 331-340 cancels both DispatchSources and closes fd (with fd >= 0 guard against double-close). tearDown called in stop(), on FIFO EOF, and on fsSource rotate event. readSource cancelHandler is a no-op by design (comment at line 144 explains why). |
| Boundaries | PASS | Empty lineBuffer after EOF flush is guarded at line 205 (`!lineBuffer.isEmpty`). Priority rawValue fallback to `.normal` on unknown strings at line 280. `groupCount` starts at 1 per init default — upsert increments so first upsert yields 2, which is correct semantics (add=1, upsert=2). |
| Security | PASS | Parsed JSON fields are used as data values only, not in shell commands or SQL. The `action` dict from pipe input passes through `parseLineAction` which validates type and required fields (lines 311-325), returning nil for unknown types rather than executing anything. |

## Defensive Programming: PASS

Crisis triage:
1. External input (pipe JSON) validated at boundaries: `processLine` decodes into a typed struct, rejects unknown fields implicitly, returns nil action for unknown types. PASS.
2. Return values checked: `open()` result checked (line 109), `fstat()` checked (line 125), `rename()` result checked (line 122-124) with NSPOSIXErrorDomain error thrown. PASS.
3. Error paths tested: testUpsertInsertsWhenNew covers the "not found" branch; testUpsertClearsDismissed covers re-surfacing after dismiss. Rotate/EOF paths are not unit-tested but are covered in prior phase review. PASS within scope.
4. No critical invariants needing runtime assertions — actor isolation provides the invariant.
5. Resources released on all paths: tearDown called from stop(), pipe EOF, and fs rotation. PASS.

## Design Quality: No significant findings

**`hasExplicitID` local variable (NotificationFileWatcher.swift:288):** Captures `desc.id != nil` into a local before the Task closure to avoid capturing the struct. This is correct and intentional — not a design smell.

**`displayTitle` computed property:** Appropriately co-located with `NotificationItemView`. The three-branch `titleView` shares one `displayTitle` rather than duplicating the `(N)` logic — this is depth over length, correct design.

**`bulkDismiss` calls `dismiss` in a loop (NotificationStore.swift:309):** Each `dismiss` call calls `markDirty` which cancels and restarts the debounced save. For large notification counts this is slightly wasteful but bounded (debounce collapses them), and the simplicity justification is solid. Not a blocker.

## Testing: PASS

| Test | Type |
|------|------|
| testUpsertUpdatesExisting | Clean (happy path) |
| testUpsertResetsTTL | Clean (happy path) |
| testUpsertInsertsWhenNew | Clean (edge: absent key) |
| testUpsertClearsDismissed | Dirty (dismissed state interaction) |
| testAddWithoutIdCreatesDistinctEntries | Dirty (backward compat invariant) |

Dirty:clean ratio is 2:3 — slightly light on dirty tests but acceptable given the narrow scope of this phase (upsert semantics on a single actor). The 5 existing pre-phase tests cover broader store correctness. The pseudocode's 5 specified tests are all present and the assertions match the spec precisely.

One minor gap: no test verifies that `isRead` is also cleared on upsert (the spec requires it alongside `isDismissed`). This is a missing assertion in `testUpsertClearsDismissed`, not a missing behavior — the implementation clears both at NotificationStore.swift:177-178. Low severity, does not affect verdict.

**Verdict: PASS**
