# Plan: Layout Save Command

**Created:** 2026-02-19
**Status:** in-progress

## Context

When you resize cells or change cell modes at runtime, those modifications live in `state.json` as `ColumnRatios`/`RowRatios` and `CellState.StackMode`. They persist across restarts but get wiped when you switch layouts. The goal: a `layout save` command (triggered via BFD hotkey) that writes current runtime layout modifications into `config.local.yaml` so they become the permanent defaults for that layout.

## Constraints

- `config.local.yaml` arrays REPLACE (don't merge) during deep merge, so we can't put modified layouts in the `layouts` array
- Need a map-based override mechanism that deep-merges cleanly
- Split ratios (per-window within cells) are excluded - they're tied to window count and too transient to be meaningful defaults
- Config cache must be invalidated after writing

## Chosen Approach: `layoutOverrides` config section

Add a new top-level `layoutOverrides` map to config. When `GetLayout()` resolves a layout, it applies overrides from this section on top of the base layout definition. The `layout save` command reads runtime state and writes overrides to `config.local.yaml`.

```yaml
# config.local.yaml
layoutOverrides:
  "3col":
    grid:
      columns: ["1fr", "3fr", "1fr"]
      rows: ["1fr"]
    cellModes:
      left: vertical
      center: tabs
      right: tabs
```

Why not write to `config.yaml` directly: avoids modifying the tracked config file and potential YAML formatting issues. The local overlay is designed for machine-specific customization.

## Implementation Checklist

### Phase 1: Config layer - `layoutOverrides` support

- [ ] Add `LayoutOverrides map[string]LayoutOverrideConfig` field to `Config` struct in `grid-cli/internal/config/types.go`
- [ ] Define `LayoutOverrideConfig` struct with `Grid *GridConfig` and `CellModes map[string]types.StackMode`
- [ ] Modify `GetLayout()` in `grid-cli/internal/config/config.go` to apply overrides before calling `ToLayout()`
- [ ] When override has `Grid.Columns`, replace the base layout's `Grid.Columns`; same for `Grid.Rows`
- [ ] When override has `CellModes`, merge into base layout's `CellModes` (override wins per-key)

**Files:** `grid-cli/internal/config/types.go`, `grid-cli/internal/config/config.go`

### Phase 2: Config writer - save overrides to local config

- [ ] Create `grid-cli/internal/config/writer.go` with `SaveLayoutOverride(layoutID string, override LayoutOverrideConfig) error`
- [ ] Function reads existing `config.local.yaml` (or creates empty map), sets `layoutOverrides.<layoutID>`, writes back atomically
- [ ] Use `yaml.Marshal`/`yaml.Unmarshal` with `map[string]any` to preserve other fields in local config
- [ ] Invalidate config cache by removing `~/.cache/thegrid/config.merged.yaml`

**Files:** `grid-cli/internal/config/writer.go`

### Phase 3: Ratio-to-track conversion utility

- [ ] Create `grid-cli/internal/layout/convert.go` with `RatiosToTrackStrings(tracks []types.TrackSize, ratios []float64) []string`
- [ ] For each flexible track, compute new fr value from ratio. Keep px/auto tracks unchanged.
- [ ] Round fr values to 2 decimal places for clean YAML output

**Files:** `grid-cli/internal/layout/convert.go`

### Phase 4: `layout save` CLI command

- [ ] Add `layoutSaveCmd` in `grid-cli/cmd/grid/main.go`
- [ ] Register as subcommand of `layoutCmd`: `layoutCmd.AddCommand(layoutSaveCmd)`
- [ ] Add to `shouldSkipMutex()` since it doesn't move windows
- [ ] Command flow: load config + state + snapshot -> get space state -> convert ratios to tracks -> collect cell modes -> call `SaveLayoutOverride()`
- [ ] Print confirmation message with what was saved

**Files:** `grid-cli/cmd/grid/main.go`

### Phase 5: BFD hotkey

- [ ] Add suggested hotkey to BFD config or document the binding

## Test Coverage

- [ ] Unit: `RatiosToTrackStrings()` with mixed fr/px tracks
- [ ] Unit: `GetLayout()` with overrides applied

## Execution Log
