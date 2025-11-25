# GridWM Layout Feature - Deviations from Spec

This document tracks any deviations from the original specifications in the `phases/` folder.

---

## Phase 0: Shared Types

### 2025-11-25 - No Deviations

**Summary:** Phase 0 was implemented exactly as specified in `PHASE0_SHARED_TYPES.md`.

All types, constants, and methods match the spec:
- StackMode, TrackType (string enums)
- Direction, AssignmentStrategy (int with iota)
- TrackSize, Cell, Layout, Rect, Point, CellBounds, WindowPlacement, CalculatedLayout (structs)
- Rect.Center(), Rect.Contains(), Direction.String(), ParseDirection() (methods)

**Files created:**
- `grid-cli/internal/types/layout_types.go`
- `grid-cli/internal/types/layout_types_test.go`

**Verification:**
- `go build ./...` - PASS
- `go test ./internal/types/... -v` - 8 tests PASS

---

## Phase 1: Config Parser

*Not yet started*

---

## Phase 2: Grid Engine

*Not yet started*

---

## Phase 3: State Manager

*Not yet started*

---

## Phase 4: Window Assignment

*Not yet started*

---

## Phase 5: CLI Commands

*Not yet started*

---

## Phase 6: Focus Navigation

*Not yet started*

---

## Phase 7: Split Ratios

*Not yet started*
