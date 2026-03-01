# Phase 1 Post-Gate Review: Add subtitle to WindowEntry and FormatWindowLine

**Verdict: PASS**

**Reviewer:** Claude Opus 4.6 (post-gate)
**Date:** 2026-02-28

---

## Checklist

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| 1 | WindowEntry struct has Subtitle field | PASS | `Subtitle string` added at line 22 of `edit.go` |
| 2 | FormatWindowLine accepts 4th subtitle param and appends `(subtitle)` when non-empty | PASS | Signature changed to `(wid uint32, appName, title, subtitle string)` in `format.go:11`. Appends ` (subtitle)` via string concatenation when subtitle is non-empty. |
| 3 | BuildBuffer passes w.Subtitle as 4th arg | PASS | `edit.go:44` now reads `FormatWindowLine(w.WID, w.AppName, w.Title, w.Subtitle)` |
| 4 | BuildBufferAll passes w.Subtitle as 4th arg | PASS | `edit.go:64` now reads `FormatWindowLine(w.WID, w.AppName, w.Title, w.Subtitle)` |
| 5 | TestFormatAndParseWindowLine tests both empty and non-empty subtitle cases | PASS | Case 1 verifies empty subtitle produces identical output to old behavior. Case 2 verifies `"2 tabs"` subtitle produces `(2 tabs)` suffix. Both cases verify ParseWindowLine roundtrip. |
| 6 | ParseWindowLine is unchanged | PASS | git diff shows zero changes to ParseWindowLine (lines 26-44 of `format.go`). Only `FormatWindowLine` was modified. |
| 7 | Tests pass | PASS | All 10 tests pass. `go test ./internal/edit/ -v` exits 0. |
| 8 | Full project compiles | PASS | `go build ./...` exits 0 with no errors or warnings. |

## Diff Summary

Three files changed, exactly matching the pseudocode specification:

- **edit.go**: Added `Subtitle string` field to `WindowEntry`; updated both `BuildBuffer` and `BuildBufferAll` call sites to pass `w.Subtitle`.
- **format.go**: Changed `FormatWindowLine` signature from 3 to 4 params; added subtitle append logic. `ParseWindowLine` untouched.
- **edit_test.go**: Extended `TestFormatAndParseWindowLine` with two cases (empty subtitle, non-empty subtitle) including exact string assertions.

No other files were modified. No regressions detected.
