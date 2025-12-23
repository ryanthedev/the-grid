# Configuration Reference

This document provides a complete reference for theGrid configuration files, targeting LLMs and developers.

## File Locations

theGrid follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `$XDG_CONFIG_HOME` | `~/.config` | User configuration directory |
| `$XDG_CONFIG_DIRS` | `/etc/xdg:/opt/homebrew/etc:/usr/local/etc` | System config paths (colon-separated) |
| `$XDG_STATE_HOME` | `~/.local/state` | Runtime state and logs |

### Config Files

| File | Purpose |
|------|---------|
| `$XDG_CONFIG_HOME/thegrid/config.yaml` | Main CLI configuration |
| `$XDG_CONFIG_HOME/thegrid/config.local.yaml` | Local overrides (gitignored) |
| `$XDG_CONFIG_HOME/thegrid/bfd.yaml` | Hotkey configuration |
| `$XDG_CONFIG_HOME/thegrid/bfd.local.yaml` | Local hotkey overrides |

### Config Resolution Order

Configs are deep-merged in priority order (lowest to highest):

1. **Built-in defaults** (hardcoded in application)
2. **System configs** (`$XDG_CONFIG_DIRS/thegrid/config.yaml`, right-to-left)
3. **User config** (`$XDG_CONFIG_HOME/thegrid/config.yaml`)
4. **Local overlay** (`$XDG_CONFIG_HOME/thegrid/config.local.yaml`)

### Merge Semantics

- **Objects**: Deep merge recursively
- **Arrays**: Replace entirely (no append)
- **Scalars**: Override wins
- **`null` value**: Explicitly removes key from result

---

## Config Schema

Root structure:

```yaml
settings: {}      # Global settings
layouts: []       # Layout definitions
spaces: {}        # Space-to-layout mappings
appRules: []      # Application-specific rules
borders: {}       # Window border configuration
```

---

## settings

Global application settings.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `defaultStackMode` | `string` | `""` | How windows stack: `"vertical"`, `"horizontal"`, `"tabs"` |
| `baseSpacing` | `float64` | `8` | Base unit for `"Nx"` padding syntax |
| `animationDuration` | `float64` | `0` | Animation duration in seconds |
| `padding` | `Padding` | `null` | Global default padding (see [Padding Syntax](#padding-syntax)) |
| `windowSpacing` | `Padding` | `null` | Gap between stacked windows |
| `focusFollowsMouse` | `bool` | `false` | Enable focus-follows-mouse |
| `resize` | `ResizeSettings` | `{}` | Resize behavior constraints |
| `windowExclusion` | `WindowExclusion` | `{}` | Windows to exclude from tiling |

### settings.resize

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `minRatio` | `float64` | `0.1` | Minimum cell ratio during resize (0.0-1.0) |
| `maxRatio` | `float64` | `0.9` | Maximum cell ratio during resize (0.0-1.0) |

### settings.windowExclusion

User-configured exclusions are **additive** to built-in defaults.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `roles` | `[]string` | `[]` | Accessibility roles to exclude |
| `subroles` | `[]string` | `[]` | Accessibility subroles to exclude |
| `apps` | `[]string` | `[]` | App names to exclude entirely |

**Built-in defaults** (always active):
- Roles: `AXHelpTag`, `AXGrowArea`, `AXScrollArea`
- Apps: `Dock`, `Control Center`, `Notification Center`

---

## layouts[]

Array of layout definitions. Each layout defines a grid and cell placement.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | `string` | **Yes** | Unique layout identifier |
| `name` | `string` | **Yes** | Human-readable name |
| `description` | `string` | No | Optional description |
| `grid` | `GridConfig` | **Yes** | Grid track definitions |
| `cells` | `[]CellConfig` | **One of** | Explicit cell definitions |
| `areas` | `[][]string` | **One of** | ASCII grid syntax |
| `cellModes` | `map[string]StackMode` | No | Per-cell stack mode overrides |
| `padding` | `Padding` | No | Layout-level default padding |
| `windowSpacing` | `Padding` | No | Layout-level window spacing |

**Note**: Must define either `cells` OR `areas`, not both.

### layouts[].grid

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `columns` | `[]string` | **Yes** | Column track sizes (see [Track Sizes](#track-sizes)) |
| `rows` | `[]string` | **Yes** | Row track sizes |

### layouts[].cells[]

Explicit cell definitions with grid line positions.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | `string` | **Yes** | Unique cell identifier |
| `column` | `string` | **Yes** | Column span: `"start/end"` format (1-indexed) |
| `row` | `string` | **Yes** | Row span: `"start/end"` format (1-indexed) |
| `stackMode` | `StackMode` | No | Override default stack mode |
| `padding` | `Padding` | No | Per-cell padding override |
| `windowSpacing` | `Padding` | No | Per-cell window spacing override |
| `border` | `CellBorderConfig` | No | Per-cell border style override |

**Column/Row span format**: `"start/end"` where both are 1-indexed grid lines.
- Grid with 2 columns has lines: 1, 2, 3
- `"1/2"` = first column, `"1/3"` = spans both columns

### layouts[].cells[].border

| Field | Type | Description |
|-------|------|-------------|
| `active_cell_color` | `string` | Override active border color |
| `inactive_color` | `string` | Override inactive border color |
| `style` | `string` | Override border style |

### layouts[].areas

ASCII grid syntax for visual cell layout. Each row is an array of cell IDs.

```yaml
areas:
  - [main, main, side]
  - [main, main, side]
  - [footer, footer, footer]
```

- Use `.` or `""` for empty cells
- Each named cell must form a complete rectangle
- Dimensions must match grid definition

---

## spaces{}

Map of space ID to space configuration. Space IDs are strings (e.g., `"1"`, `"2"`).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `string` | No | Display name for the space |
| `layouts` | `[]string` | **Yes** | Layout IDs available for this space |
| `defaultLayout` | `string` | **Yes** | Initial layout when switching to space |
| `autoApply` | `bool` | No | Auto-apply layout on space switch |

---

## appRules[]

Application-specific window behavior rules.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `app` | `string` | **Yes** | App name or bundle ID |
| `preferredCell` | `string` | No | Cell ID to prefer for this app |
| `layouts` | `[]string` | No | Only applies to these layout IDs |
| `float` | `bool` | No | Never tile this app (`true` = floating) |
| `preferredStackMode` | `StackMode` | No | Stack mode preference for this app |

---

## borders

Window border appearance configuration.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | `bool` | `false` | Master switch for borders |
| `active` | `BorderStyle` | See below | Active window border style |
| `inactive` | `InactiveBorderStyle` | See below | Inactive window border style |

### borders.active / borders.inactive

| Field | Type | Default (active) | Default (inactive) | Description |
|-------|------|------------------|-------------------|-------------|
| `enabled` | `bool` | N/A | `true` | Enable inactive borders |
| `color` | `string` | `"#FF0000"` | `"#666666"` | Border color (hex) |
| `width` | `float64` | `3.0` | `3.0` | Border stroke width |
| `cornerRadius` | `float64` | `8.0` | `8.0` | Corner radius |
| `opacity` | `float64` | `1.0` | `1.0` | Stroke opacity (0.0-1.0) |
| `glowRadius` | `float64` | `null` | `null` | Glow effect size |
| `glowColor` | `string` | `null` | `null` | Glow color |
| `glowOpacity` | `float64` | `null` | `null` | Glow opacity |
| `glowSpread` | `float64` | `null` | `null` | Glow spread |
| `shadowRadius` | `float64` | `null` | `null` | Shadow blur radius |
| `shadowOffset` | `[x, y]` | `null` | `null` | Shadow offset |
| `shadowColor` | `string` | `null` | `null` | Shadow color |
| `shadowOpacity` | `float64` | `null` | `null` | Shadow opacity |
| `animation` | `AnimationConfig` | `null` | `null` | Animation settings |

### borders.*.animation

| Field | Type | Description |
|-------|------|-------------|
| `type` | `string` | Animation type: `"none"`, `"pulse"`, `"breathe"`, `"fade"` |
| `duration` | `float64` | Animation duration in seconds |
| `intensity` | `float64` | Animation intensity (0.0-1.0) |

---

## Value Formats

### Stack Modes

| Value | Description |
|-------|-------------|
| `"vertical"` | Windows stack top-to-bottom |
| `"horizontal"` | Windows stack left-to-right |
| `"tabs"` | Only one window visible at a time |

### Track Sizes

Grid column and row track definitions.

| Format | Example | Description |
|--------|---------|-------------|
| Fractional | `"1fr"`, `"2.5fr"` | Proportional distribution of remaining space |
| Fixed | `"300px"`, `"100.5px"` | Exact pixel size |
| Auto | `"auto"` | Content-based sizing |
| MinMax | `"minmax(200px, 1fr)"` | Minimum fixed, maximum flexible |

### Padding Syntax

Padding can be specified in multiple formats:

**Single value** (all sides):
```yaml
padding: 10           # 10 pixels all sides
padding: "10px"       # 10 pixels all sides
padding: "2x"         # 2 × baseSpacing all sides
padding: "1.5x"       # 1.5 × baseSpacing all sides
```

**Two values** (vertical, horizontal):
```yaml
padding: [10, 5]      # vertical=10px, horizontal=5px
```

**Four values** (top, right, bottom, left - CSS order):
```yaml
padding: [10, 5, 8, 5]  # explicit per-direction
```

**Object** (explicit):
```yaml
padding:
  top: 10
  right: 5
  bottom: 8
  left: 5
```

**Base-relative** (`"Nx"` notation):
- Multiplies `baseSpacing` setting
- `"2x"` with `baseSpacing: 8` = 16 pixels

---

## BFD Hotkey Configuration

Separate file: `$XDG_CONFIG_HOME/thegrid/bfd.yaml`

### Schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `shell` | `string` | `"/bin/zsh"` | Shell for command execution |
| `vars` | `map[string]string` | `{}` | Variable substitutions |
| `defaults` | `BFDDefaults` | See below | Default hotkey behavior |
| `blacklist` | `[]string` | `[]` | App bundle IDs where hotkeys disabled |
| `hotkeys` | `map[string]HotkeyDef` | `{}` | Global hotkey definitions |
| `apps` | `map[string]map[string]AppHotkey` | `{}` | Per-app hotkey overrides |

### defaults

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `repeat` | `bool` | `false` | Allow key repeat |
| `rate_limit` | `int` | `50` | Minimum ms between repeats |

### Hotkey Syntax

**Simple command**:
```yaml
hotkeys:
  ctrl-h: ${grid} focus left
  ctrl-j: ${grid} focus down
```

**Extended format**:
```yaml
hotkeys:
  ctrl-h:
    run: ${grid} focus left
    repeat: true
    rate_limit: 100
```

**Variable substitution**: Use `${varname}` to reference vars.

### Per-App Overrides

```yaml
apps:
  com.apple.Terminal:
    ctrl-h: ~                     # Passthrough (let app handle it)
    ctrl-j: ${grid} focus down    # Override command
```

- `~` = passthrough (disable hotkey for this app)
- String = override command
- Extended format = override with settings

---

## Validation Rules

The configuration is validated on load. Invalid configs are rejected.

### Config-level
- All layout IDs must be unique
- All layouts referenced by spaces must exist
- All app rules must have an `app` identifier

### Layout-level
- Must have both `grid.columns` and `grid.rows`
- Track sizes must be valid format
- Must define either `cells` or `areas` (not both, not neither)

### Cell-level
- Each cell must have unique ID within layout
- Column/row spans must be within grid bounds
- Column/row spans must use valid `"start/end"` format (start < end)
- Stack mode must be valid if specified

### Areas-level
- Dimensions must match grid definition (rows × columns)
- Each named cell must form a complete rectangle

### Settings-level
- `defaultStackMode` must be valid if specified
- `animationDuration` cannot be negative
- `baseSpacing` cannot be negative

---

## Debugging Commands

```bash
# Show XDG paths and which config files exist
thegrid config sources

# Show final merged configuration as YAML
thegrid config show

# Validate configuration without running
thegrid config validate
```

---

## Complete Example

```yaml
# ~/.config/thegrid/config.yaml

settings:
  defaultStackMode: vertical
  baseSpacing: 8
  animationDuration: 0.2
  focusFollowsMouse: false
  padding: "1x"
  windowSpacing: 4
  resize:
    minRatio: 0.15
    maxRatio: 0.85
  windowExclusion:
    apps:
      - "Alfred"
      - "Raycast"

layouts:
  - id: two-column
    name: Two Column
    grid:
      columns: ["1fr", "1fr"]
      rows: ["1fr"]
    cells:
      - id: left
        column: "1/2"
        row: "1/2"
      - id: right
        column: "2/3"
        row: "1/2"
        stackMode: tabs

  - id: main-side
    name: Main + Side
    grid:
      columns: ["2fr", "1fr"]
      rows: ["1fr", "1fr"]
    areas:
      - [main, side]
      - [main, side]
    cellModes:
      side: horizontal

  - id: three-column
    name: Three Column
    grid:
      columns: ["1fr", "2fr", "1fr"]
      rows: ["1fr"]
    cells:
      - id: left
        column: "1/2"
        row: "1/2"
        padding: [8, 4, 8, 8]
      - id: center
        column: "2/3"
        row: "1/2"
        padding: [8, 4, 8, 4]
      - id: right
        column: "3/4"
        row: "1/2"
        padding: [8, 8, 8, 4]

spaces:
  "1":
    name: Main
    layouts: [two-column, main-side]
    defaultLayout: two-column
    autoApply: true
  "2":
    name: Code
    layouts: [three-column, two-column]
    defaultLayout: three-column
    autoApply: true

appRules:
  - app: "Terminal"
    preferredCell: left
    preferredStackMode: horizontal
  - app: "Finder"
    float: true
  - app: "Safari"
    preferredCell: right
    layouts: [two-column]

borders:
  enabled: true
  active:
    color: "#6366f1"
    width: 2
    cornerRadius: 12
    opacity: 1.0
    glowRadius: 4
    glowColor: "#6366f1"
    glowOpacity: 0.3
  inactive:
    enabled: true
    color: "#404040"
    width: 1
    cornerRadius: 12
    opacity: 0.5
```
