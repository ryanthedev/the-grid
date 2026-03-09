# Review: Phase 3b - Window Assignment + Classification

## Verdict: PASS

## Spec Match
- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage verified (plan specifies: "Unit test `classifyWindow()` and `assignAutoFlow()` with mock windows" -- deferred to checkpoint phase per plan structure)

### Section-by-Section Mapping

| Pseudocode Section | Implementation | Status |
|---|---|---|
| `CGRect.overlapArea` extension | `GridLayout.swift:41-52` | MATCH |
| `MinTileableDimension` constant | `GridAssignment.swift:8` | MATCH |
| `GridWindowCategory` enum | `GridAssignment.swift:12-16` | MATCH |
| `GridAssignmentResult` struct | `GridAssignment.swift:20-27` | MATCH (added `Sendable`) |
| `terminalApps` set | `GridAssignment.swift:33-37` | MATCH |
| `classifyWindow()` | `GridAssignment.swift:43-103` | MATCH |
| `isTileable()` | `GridAssignment.swift:108-128` | MATCH |
| `isExcluded()` | `GridAssignment.swift:131-146` | MATCH |
| `matchesAppRule()` | `GridAssignment.swift:151-157` | MATCH |
| `shouldFloat()` | `GridAssignment.swift:160-176` | MATCH |
| `shouldExclude()` | `GridAssignment.swift:179-181` | MATCH |
| `getPreferredCell()` | `GridAssignment.swift:184-196` | MATCH |
| `GridAssignment.assignWindows()` | `GridAssignment.swift:214-289` | MATCH |
| `assignAutoFlow()` | `GridAssignment.swift:294-317` | MATCH |
| `assignPinned()` | `GridAssignment.swift:320-361` | MATCH |
| `assignPreserve()` | `GridAssignment.swift:364-425` | MATCH |
| `assignByPosition()` | `GridAssignment.swift:428-472` | MATCH |
| `findLeastPopulatedCell()` | `GridAssignment.swift:478-484` | MATCH |

### Deviations (all acceptable)

1. **`GridAssignmentResult` marked `Sendable`** -- not in pseudocode but required for actor isolation. Pure value type, no issue.
2. **Helper functions at module level instead of inside enum** -- `classifyWindow`, `isTileable`, `isExcluded`, `matchesAppRule`, `shouldFloat`, `shouldExclude`, `getPreferredCell` are module-level functions rather than static methods on `GridAssignment`. The pseudocode shows them at module level too (not indented under `enum GridAssignment`), so this matches. `classifyWindow`, `isTileable`, and `isExcluded` are appropriately non-private for external use by the reconciler.
3. **`assignByPosition` builds zOrderLookup at top** -- pseudocode puts it inline in the sort section. Implementation pre-computes it once before the loop. Functionally identical, slightly more efficient.

## Dead Code
None found. All functions are either:
- Called from `assignWindows` (the entry point)
- Public utility functions needed by future reconciler/apply phases (`classifyWindow`, `isTileable`, `isExcluded`)

No unused imports, no commented-out blocks, no debug statements, no unreachable code after early returns.

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 4 assignment strategies implemented. Window classification with PIP detection matches pseudocode. App rule matching, tileable filtering, exclusion checking all present. |
| Concurrency | N/A | All functions are pure/stateless. `GridAssignmentResult` is `Sendable`. No shared mutable state. |
| Error Handling | PASS | `findLeastPopulatedCell` returns `""` when assignments is empty (defensive). `overlapArea` returns 0 for non-overlapping rects. Nil-coalescing on optional fields (`role ?? ""`, `appName ?? ""`, `bundleID ?? ""`). |
| Resource Mgmt | N/A | No resources acquired -- pure computation only. |
| Boundaries | PASS | Empty windows array: `assignAutoFlow` returns early. Empty cells: guarded. `findLeastPopulatedCell` with empty map returns `""`. Position assignment with no overlap falls back to least-populated cell. Preserve strategy handles missing previous assignments gracefully. |
| Security | N/A | No untrusted external input -- operates on server-internal AX state. |

## Defensive Programming

### Crisis Invariants Checked
- **No empty catch blocks**: No try/catch in this module (pure functions, no throwing).
- **No executable code in assertions**: No assertions used (appropriate -- no debug-only checks needed in pure computation).
- **External input validated**: Input comes from server-internal `WindowState` and config types. `bundleIDLookup` closure returns optional, properly nil-coalesced.

### Additional Checks
- **No swallowed errors**: No error suppression patterns found.
- **No broad exception types**: No exception handling needed (non-throwing code).
- **Consistent error strategy**: Functions return empty/default values for edge cases rather than crashing. Matches robustness-oriented strategy appropriate for a window manager.
- **`findLeastPopulatedCell` returns `""`**: If called with empty `assignments` dictionary, returns empty string. This is safe because the callers (`assignPinned`, `assignPreserve`, `assignByPosition`) only reach `findLeastPopulatedCell` when there are cells in `result.assignments` (initialized from `layout.cells` in `assignWindows`). If `layout.cells` were empty, the tileable windows would have nowhere to go, and the strategies all guard against empty cells/windows.

## Notes
- `isExcluded()` is defined but not called within `GridAssignment.swift` itself. Per the pseudocode and discovery doc, it is a utility for the future reconciler (Phase 4). This is not dead code -- it is an intentional public API for downstream consumers.
- `isTileable()` is similarly defined for external use. The assignment entry point uses `shouldExclude()` and `shouldFloat()` for its own classification, which is correct per pseudocode.
