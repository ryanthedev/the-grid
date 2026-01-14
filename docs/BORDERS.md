# Border Configuration

Borders are overlay windows drawn around application windows to highlight focus state. They support glow and shadow effects for visual polish.

## Quick Start

```yaml
borders:
  enabled: true      # Master switch for all borders

  active:            # Focused window
    color: "#6366f1"
    width: 2
    cornerRadius: 12
    opacity: 1.0

  inactive:          # Unfocused windows
    enabled: false   # Set true to show borders on inactive windows
```

## How It Works

Each effect (border stroke, glow, shadow) is independent:

| Want | How |
|------|-----|
| Border only | Set `width` and `opacity`, leave glow/shadow at 0 |
| Glow only | Set `opacity: 0` to hide stroke, set `glowRadius` > 0 |
| Shadow only | Set `opacity: 0` to hide stroke, set `shadowRadius` > 0 |
| Glow + Shadow | Set `opacity: 0`, set both `glowRadius` and `shadowRadius` > 0 |
| Everything | Set all values > 0 |
| Disable inactive | Set `inactive.enabled: false` |

## Property Reference

### Border Stroke

| Property | Range | Default | Description |
|----------|-------|---------|-------------|
| `enabled` | bool | true | Master switch (top-level or per inactive) |
| `color` | string | #6366f1 | Hex `#RGB`, `#RRGGBB`, or `#RRGGBBAA` |
| `width` | 1-20 | 2 | Stroke width in pixels |
| `cornerRadius` | 0-50 | 8 | Corner radius in pixels (0 = square) |
| `opacity` | 0-1 | 1.0 | Stroke visibility (0 = invisible) |

### Glow Effect

Set `glowRadius: 0` to disable glow entirely.

| Property | Range | Default | Description |
|----------|-------|---------|-------------|
| `glowRadius` | 0-50 | 0 | Blur radius (0 = disabled) |
| `glowColor` | string | border color | Glow color |
| `glowOpacity` | 0-1 | 0.5 | Glow intensity |
| `glowSpread` | 0.1+ | 1.0 | Spread multiplier (larger = wider glow) |

### Shadow Effect

Set `shadowRadius: 0` to disable shadow entirely.

| Property | Range | Default | Description |
|----------|-------|---------|-------------|
| `shadowRadius` | 0-100 | 0 | Blur radius (0 = disabled) |
| `shadowOffset` | [-100, 100] | [2, 4] | [x, y] offset in pixels |
| `shadowColor` | string | #000000 | Shadow color |
| `shadowOpacity` | 0-1 | 0.5 | Shadow intensity |

### Stack Indicator

Visual indicator showing which window is active within a tabbed/stacked cell. Displayed as small lines on the border edge facing the screen center.

| Property | Range | Default | Description |
|----------|-------|---------|-------------|
| `enabled` | bool | true | Show/hide stack indicator |
| `lineLength` | 1-100 | 12 | Length of each indicator line in pixels |
| `lineWidth` | 1-20 | 3 | Width of each indicator line in pixels |
| `spacing` | 0-50 | 6 | Space between indicator lines in pixels |
| `position` | string | "auto" | Edge position: "auto", "left", "right", "top", "bottom" |
| `activeColor` | string | border color | Color for the active window indicator |
| `inactiveColor` | string | #000000 | Color for inactive window indicators |

**Position behavior:**
- `auto`: Automatically places indicator on the edge facing screen center (inward edge)
- Fixed positions override automatic detection

**Visual style:**
- Active window: filled with border color, black outline
- Inactive windows: filled with black, border color outline

### Animation (Not Yet Implemented)

Config is parsed but not applied. Documented for future use.

```yaml
animation:
  type: "pulse"
  duration: 2.0
  intensity: 0.5
```

## Examples

### Simple Border

Standard visible border, no effects:

```yaml
borders:
  enabled: true
  active:
    color: "#3b82f6"
    width: 2
    cornerRadius: 8
    opacity: 1.0
  inactive:
    enabled: false
```

### Glow Only

Invisible stroke with prominent glow. Use `opacity: 0` to hide the border stroke while keeping the glow visible:

```yaml
borders:
  enabled: true
  active:
    color: "#22c55e"
    width: 1            # Still needed for glow path
    cornerRadius: 12
    opacity: 0          # Hides the stroke
    glowRadius: 20
    glowColor: "#22c55e"
    glowOpacity: 0.7
    glowSpread: 1.2
  inactive:
    enabled: false
```

### Shadow Only

Drop shadow without visible border:

```yaml
borders:
  enabled: true
  active:
    color: "#000000"
    width: 1
    cornerRadius: 12
    opacity: 0          # Hides the stroke
    shadowRadius: 12
    shadowOffset: [0, 4]
    shadowColor: "#000000"
    shadowOpacity: 0.5
  inactive:
    enabled: false
```

### Subtle Focus

Thin border with soft glow:

```yaml
borders:
  enabled: true
  active:
    color: "#3b82f6"
    width: 1
    cornerRadius: 8
    opacity: 0.8
    glowRadius: 10
    glowOpacity: 0.4
  inactive:
    enabled: false
```

### Full Effect with Inactive Borders

Border with glow and shadow on both active and inactive windows:

```yaml
borders:
  enabled: true
  active:
    color: "#8b5cf6"
    width: 2
    cornerRadius: 12
    opacity: 1.0
    glowRadius: 12
    glowOpacity: 0.5
    shadowRadius: 8
    shadowOffset: [2, 4]
    shadowOpacity: 0.3
  inactive:
    enabled: true
    color: "#64748b"
    width: 1
    cornerRadius: 12
    opacity: 0.5
    glowRadius: 0
    shadowRadius: 0
```

### Custom Stack Indicator

Larger indicator with custom colors:

```yaml
borders:
  enabled: true
  active:
    color: "#3b82f6"
    width: 3
    cornerRadius: 12
    opacity: 1.0
    stackIndicator:
      enabled: true
      lineLength: 16
      lineWidth: 4
      spacing: 8
      position: "auto"      # or "left", "right", "top", "bottom"
      activeColor: "#22c55e"
      inactiveColor: "#1e293b"
```

### Disable Stack Indicator

Hide the indicator while keeping borders:

```yaml
borders:
  active:
    color: "#3b82f6"
    stackIndicator:
      enabled: false
```

## Notes

- **Disabling effects**: Set radius to 0 (e.g., `glowRadius: 0`, `shadowRadius: 0`)
- **Hiding border stroke**: Set `opacity: 0` (width is still used for effect positioning)
- **Disabling inactive borders**: Set `inactive.enabled: false`
- **Disabling all borders**: Set top-level `enabled: false`
- **Disabling stack indicator**: Set `stackIndicator.enabled: false`
- Effects extend beyond the border stroke; overlay windows expand automatically
- Values outside valid ranges are clamped automatically
- Stack indicator only appears on active border when cell has multiple windows
