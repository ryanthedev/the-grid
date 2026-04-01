# Phase 5 Discovery: Default Presets + Documentation

**Date:** 2026-03-31
**Phase:** 5 of 5 (final)
**Status:** Complete

## Current State

### AnimationConfig (AnimationConfig.swift)

The default preset is already defined in `AnimationConfig.builtinDefault`:

```swift
static let builtinDefault = AnimationConfig(
    defaultPreset: AnimationPreset(
        arrival: ["slide_in", "matrix_title", "arrival_flash", "fade_to_ghost", "spinner", "breathing"],
        idle: ["wave_title", "spinner", "breathing", "fade_to_ghost"],
        warning: ["shake", "grow", "border_strobe", "warning_pulse", "progress_bar", "spinner", "fade_to_ghost"],
        ghost: ["fade_to_ghost", "wave_title", "spinner", "breathing"]
    ),
    sourcePresets: [:]
)
```

**Gap:** `sourcePresets` is empty. No source-specific presets (iMessage, CI, urgent, generic).

### YAML Config Structure (AnimationConfig.swift)

The loader (`loadAnimationConfigFromYAML()`) expects this structure:

```yaml
animations:
  default:
    arrival: [slide_in, matrix_title, ...]
    idle: [wave_title, ...]
    warning: [shake, grow, ...]
    ghost: [fade_to_ghost, ...]
  sources:
    imessage:
      arrival: [...]
    ci:
      arrival: [...]
    urgent:
      arrival: [...]
    generic:
      arrival: [...]
```

**Gap:** No example or documentation of this YAML structure for users.

### NotificationPanelViews Help View (NotificationPanelViews.swift, lines 610-679)

The help view exists and displays keybindings. It has two sections:
- Normal Mode: navigation, dismiss, pin, priority, action, filter, visual select, help, exit
- Visual Select: extension, bulk dismiss, bulk pin, exit

**Gap:** No animation catalog section. Users cannot discover available animations or which ones are active for their source.

### AnimationRegistry (AnimationEngine.swift)

All 32 animations are registered:

**Phase 1 (12):** shake, breathing, slide_in, grow, border_strobe, fade_to_ghost, matrix_title, wave_title, progress_bar, warning_pulse, arrival_flash, spinner

**Phase 2 (8):** glitch, redact, typing_indicator, scanline, bounce, accordion, tilt, parallax

**Phase 3 (4):** gradient_sweep, heatmap, neon_flicker, chromatic_aberration

**Phase 4 (8):** hourglass_sprite, pie_countdown, heartbeat, dissolve, cursor_blink, boot_sequence, stack_trace, ascii_border

**Accessible via:** `AnimationRegistry.shared.registeredNames` (returns sorted list of all names)

### Notification.swift (GridNotification model)

Notifications support per-notification animation overrides via `animationOverride` field. Priority resolution:
1. Per-notification override (JSON `animations` field)
2. Source preset (from notify.yaml)
3. Default preset (hardcoded builtin)

---

## Done-When Analysis

**DW-5.1: Default presets defined for iMessage, generic, CI, and urgent sources**

- Current: Empty `sourcePresets: [:]` in `AnimationConfig.builtinDefault`
- Needed: Populate `AnimationConfig.builtinDefault.sourcePresets` with iMessage, generic, CI, urgent entries
- File: `AnimationConfig.swift` (modify `builtinDefault` static property)

**DW-5.2: Help view lists all available animation names by category**

- Current: Only keybindings shown (lines 614-632). No animation section.
- Needed: Add new section with 32 animations grouped by category (text, spatial, color, mood, progress, terminal)
- File: `NotificationPanelViews.swift` (expand `NotificationHelpView.body`)
- Categorization:
  - **Text:** matrix_title, wave_title, glitch, redact, typing_indicator, cursor_blink, chromatic_aberration
  - **Spatial:** slide_in, bounce, accordion, tilt, parallax, scanline
  - **Color/Mood:** gradient_sweep, heatmap, neon_flicker
  - **Progress:** hourglass_sprite, pie_countdown, heartbeat, progress_bar
  - **Terminal/Lifecycle:** shake, grow, warning_pulse, border_strobe, spinner, breathing, fade_to_ghost, dissolve, ascii_border, boot_sequence, stack_trace, arrival_flash

**DW-5.3: With no animation config in notify.yaml, default presets produce same visual behavior**

- Current: `builtinDefault` already defined and used as fallback in `loadAnimationConfigFromYAML()`
- Needed: Verify that animations match the original hardcoded behavior (they do — lines 60-63 of AnimationConfig.swift match original)
- Already satisfied by Phase 1 implementation

---

## Documentation Gaps

No `docs/animations.md` file exists. Needed:

- Full animation catalog with names, categories, descriptions, affected phases, visual effects
- Example YAML config snippets
- Per-notification JSON override examples
- Best practices for source-specific presets

---

## File Inventory

| File | Purpose | Status |
|------|---------|--------|
| `AnimationConfig.swift` | Default preset + source-specific presets | **Needs modification:** Add iMessage/generic/CI/urgent presets |
| `NotificationPanelViews.swift` | Help view | **Needs modification:** Add animation catalog section |
| `docs/animations.md` | Animation reference | **Does not exist** |

---

## Constraints & Notes

- Default presets must match pre-engine behavior for backward compatibility ✓ (already done)
- Help view groups animations by category ✓ (plan calls for this)
- Animation reference doc in docs/ directory ✓ (plan calls for this)
- No new animations beyond 32 ✓ (constraint met)

---

## Next Steps

1. Define source-specific presets (iMessage, generic, CI, urgent) in `AnimationConfig.swift`
2. Update `NotificationHelpView` to list all 32 animations grouped by category
3. Create `docs/animations.md` with full animation catalog and usage guide
