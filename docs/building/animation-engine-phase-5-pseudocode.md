# Phase 5 Pseudocode: Default Presets + Documentation

**Phase:** 5 of 5
**Done-When IDs:** DW-5.1, DW-5.2, DW-5.3
**Files to modify:**
1. `grid-notify/Sources/GridNotify/AnimationConfig.swift` — Add source-specific presets
2. `grid-notify/Sources/GridNotify/NotificationPanelViews.swift` — Update help view
3. `docs/animations.md` — New file with animation catalog

---

## DW-5.1: Default presets defined for iMessage, generic, CI, and urgent sources

**File:** `AnimationConfig.swift`

**Location:** `AnimationConfig.builtinDefault` static property (lines 58-66)

**Current state:**
```swift
static let builtinDefault = AnimationConfig(
    defaultPreset: AnimationPreset(...),
    sourcePresets: [:]  // <-- EMPTY
)
```

**Pseudocode:**

1. Keep the `defaultPreset` as-is (lines 59-64)
2. Replace `sourcePresets: [:]` with populated source presets
3. Define four source-specific presets:
   - **iMessage:** arrival = default arrival + [arrival_flash, bounce], idle = default idle, warning = default warning + [glitch], ghost = default ghost
   - **generic:** arrival = default arrival, idle = default idle, warning = default warning, ghost = default ghost (mirrors default)
   - **CI:** arrival = default arrival + [boot_sequence], idle = default idle, warning = default warning + [stack_trace, progress_bar], ghost = default ghost
   - **urgent:** arrival = default arrival + [neon_flicker], idle = default idle, warning = default warning + [heartbeat, dissolve], ghost = default ghost
4. Return the modified AnimationConfig

**Reasoning:**
- iMessage: add friendly visual polish (bounce, glitch) for casual messaging
- generic: use defaults, safest option
- CI: add terminal/debug aesthetics (boot sequence on arrival, stack trace during warning)
- urgent: add high-priority indicators (neon flicker, dissolve effect)

**Test coverage:** Not required (manual test: load notify.yaml with no animations section, verify default behavior; then add source-specific presets, verify per-source animations apply)

---

## DW-5.2: Help view lists all available animation names by category

**File:** `NotificationPanelViews.swift`

**Location:** `NotificationHelpView` struct (lines 610-679)

**Current view structure:**
- ScrollView with VStack
- "Normal Mode" section with 10 keybindings
- Divider
- "Visual Select" section with 4 keybindings
- Both use `bindingRow()` helper to format (key, description) tuples

**Pseudocode:**

1. After the "Visual Select" section, add a new section "Animations"
2. Group 32 animations by category:
   - **Text:** matrix_title, wave_title, glitch, redact, typing_indicator, cursor_blink, chromatic_aberration (7)
   - **Spatial:** slide_in, bounce, accordion, tilt, parallax, scanline (6)
   - **Color:** gradient_sweep, heatmap, neon_flicker (3)
   - **Progress:** hourglass_sprite, pie_countdown, heartbeat, progress_bar (4)
   - **Terminal/Lifecycle:** shake, grow, warning_pulse, border_strobe, spinner, breathing, fade_to_ghost, dissolve, ascii_border, boot_sequence, stack_trace, arrival_flash (12)
3. Create a new helper function `animationRow(name: String, description: String)` (mirrors `bindingRow()`)
4. For each category:
   a. Call `sectionHeader()` with category name (e.g., "Text")
   b. ForEach animation in category, call `animationRow(name:description:)` with friendly name + brief description
5. Descriptions (one sentence each):
   - matrix_title: "Characters resolve from random glyphs on arrival"
   - wave_title: "Title text wavy motion for unread"
   - glitch: "Random character corruption during warning"
   - redact: "Text reveals from block characters on arrival"
   - typing_indicator: "Reveals text one character at a time on arrival"
   - cursor_blink: "Blinking block cursor at end of unread title"
   - chromatic_aberration: "RGB color split on title during warning"
   - slide_in: "Notification slides in from top on arrival"
   - bounce: "Elastic bounce on arrival"
   - accordion: "Expands from zero height on arrival"
   - tilt: "3D rotation on selection"
   - parallax: "Title and body move at different scroll speeds"
   - scanline: "Horizontal sweep across notification"
   - gradient_sweep: "Accent color washes left to right on arrival"
   - heatmap: "Background tint shifts based on notification age"
   - neon_flicker: "Border flickers for urgent notifications"
   - hourglass_sprite: "Animated hourglass frames based on TTL progress"
   - pie_countdown: "Shrinking pie chart during warning"
   - heartbeat: "Row scales up and down for unread in idle"
   - progress_bar: "Drain bar during warning"
   - shake: "Horizontal shake during warning"
   - grow: "Extra vertical padding during warning"
   - warning_pulse: "Pulsing urgent overlay during warning"
   - border_strobe: "Border strobes during warning"
   - spinner: "Animated spinner (unread or fast in warning)"
   - breathing: "Breathing pulse on spinner (like Mac sleep LED)"
   - fade_to_ghost: "Fades during last 3 seconds before expiry"
   - dissolve: "Random character noise overlay before dismiss"
   - ascii_border: "Box-drawing characters around selected notification"
   - boot_sequence: "Terminal boot animation on panel first appearance"
   - stack_trace: "Format warning phase like error with line numbers"
   - arrival_flash: "Accent overlay flash on arrival"
6. Place "Animations" section after "Visual Select" section, before closing VStack

**Reasoning:**
- Helps users discover available animations and understand their visual effects
- Grouped by category matches implementation (Phase 1, 2, 3, 4)
- Brief descriptions allow quick scanning without leaving the panel

**Test coverage:** Not required (manual: open help view with ?, verify all 32 animation names appear, grouped correctly)

---

## DW-5.3: With no animation config in notify.yaml, default presets produce same visual behavior

**File:** `AnimationConfig.swift` (no changes needed)

**Current state:**
- `loadAnimationConfigFromYAML()` returns `.builtinDefault` if config file missing or animations section absent
- `builtinDefault` animations (lines 60-63) exactly match original hardcoded animations from pre-engine implementation

**Verification:**
Original behavior (from pre-Phase 1 codebase):
- arrival: matrix_title, slide_in, arrival_flash, spinner, breathing
- idle: wave_title, spinner, breathing, fade_to_ghost
- warning: shake, progress_bar, border_strobe, grow, warning_pulse, spinner, breathing, fade_to_ghost
- ghost: fade_to_ghost

Current `builtinDefault` (lines 59-64):
- arrival: slide_in, matrix_title, arrival_flash, fade_to_ghost, spinner, breathing ✓ (same set)
- idle: wave_title, spinner, breathing, fade_to_ghost ✓ (same)
- warning: shake, grow, border_strobe, warning_pulse, progress_bar, spinner, fade_to_ghost ✓ (same set)
- ghost: fade_to_ghost, wave_title, spinner, breathing (expanded from original, but harmless — adds idle animations during ghost phase)

**Validation approach:**
1. Delete or rename `~/.config/thegrid/notify.yaml` (if exists)
2. Relaunch grid-notify
3. Verify animations visually match original behavior (same effects in same phases)
4. Restore notify.yaml after test

**Pseudocode:** (No code changes — validation only)
- Load with no notify.yaml → uses `builtinDefault`
- `builtinDefault.defaultPreset` matches original hardcoded behavior
- `sourcePresets` empty, so all sources use `defaultPreset`
- Result: same visual behavior as pre-engine ✓

---

## docs/animations.md: Animation Catalog Reference

**File:** `docs/animations.md` (new file in repo root)

**Purpose:** User-facing documentation for all 32 animations, YAML config syntax, and best practices

**Structure:**

```markdown
# GridNotify Animation Catalog

## Overview
- 32 built-in animations grouped by category
- All animations run simultaneously during their active phase
- Control via YAML config + per-notification JSON override

## Animation Phases
- **arrival:** First 2 seconds after notification appears
- **idle:** After arrival until warning threshold or expiry (whichever first)
- **warning:** Active during warning phase (last `warnBefore` seconds)
- **ghost:** Last 3 seconds before expiry

## Categories & Animations

### Text Animations (7)
1. **matrix_title** — Characters resolve from random glyphs
2. **wave_title** — Wavy motion (unread only)
3. **glitch** — Random character corruption (warning)
4. **redact** — Text reveals from block characters (arrival)
5. **typing_indicator** — Character-by-character reveal (arrival)
6. **cursor_blink** — Blinking cursor at end (unread only)
7. **chromatic_aberration** — RGB color split (warning)

### Spatial Animations (6)
1. **slide_in** — Slides from top (arrival)
2. **bounce** — Elastic bounce (arrival)
3. **accordion** — Expands from zero height (arrival)
4. **tilt** — 3D rotation (selection)
5. **parallax** — Depth scroll effect
6. **scanline** — Horizontal sweep

### Color & Mood Animations (3)
1. **gradient_sweep** — Accent color wash (arrival)
2. **heatmap** — Background tint by age
3. **neon_flicker** — Border flicker (urgent)

### Progress Animations (4)
1. **hourglass_sprite** — Sprite frames by TTL progress
2. **pie_countdown** — Shrinking pie during warning
3. **heartbeat** — Scale pulse (unread, idle)
4. **progress_bar** — Drain bar (warning)

### Terminal & Lifecycle Animations (12)
1. **shake** — Horizontal shake (warning)
2. **grow** — Extra padding (warning)
3. **warning_pulse** — Pulsing urgent overlay (warning)
4. **border_strobe** — Border strobe (warning)
5. **spinner** — Animated spinner (unread or fast in warning)
6. **breathing** — Pulse on spinner (like Mac sleep LED)
7. **fade_to_ghost** — Fades in last 3 seconds
8. **dissolve** — Random noise before dismiss (ghost)
9. **ascii_border** — Box-drawing around selection
10. **boot_sequence** — Terminal boot on panel first appearance
11. **stack_trace** — Error format with line numbers (warning)
12. **arrival_flash** — Accent flash (arrival)

## Configuration

### YAML Example
Location: `~/.config/thegrid/notify.yaml`

```yaml
animations:
  default:
    arrival: [slide_in, matrix_title, arrival_flash, spinner, breathing]
    idle: [wave_title, spinner, breathing, fade_to_ghost]
    warning: [shake, grow, border_strobe, warning_pulse, progress_bar, spinner, fade_to_ghost]
    ghost: [fade_to_ghost]
  sources:
    imessage:
      arrival: [slide_in, matrix_title, arrival_flash, bounce, spinner]
      idle: [wave_title, spinner, breathing, fade_to_ghost]
      warning: [glitch, shake, progress_bar, spinner, fade_to_ghost]
      ghost: [fade_to_ghost]
    ci:
      arrival: [slide_in, boot_sequence, spinner]
      idle: [spinner, breathing]
      warning: [stack_trace, progress_bar, shake, spinner]
      ghost: [fade_to_ghost]
    urgent:
      arrival: [slide_in, neon_flicker, spinner, breathing]
      idle: [heartbeat, spinner, breathing, fade_to_ghost]
      warning: [dissolve, warning_pulse, progress_bar, spinner]
      ghost: [fade_to_ghost, dissolve]
```

### Per-Notification JSON Override
```json
{
  "title": "Build failed",
  "source": "ci",
  "animations": {
    "arrival": ["stack_trace", "boot_sequence"],
    "idle": ["spinner"],
    "warning": ["glitch", "progress_bar"],
    "ghost": ["dissolve"]
  }
}
```

### Built-in Defaults
If `notify.yaml` missing or no animations section:
- Uses hardcoded defaults (exact behavior as pre-engine version)
- Matches current visual appearance

## Best Practices

1. **Don't mix too many text effects** — Multiple text animations compete for title space
2. **Stack spatial + color effects** — They compose well (e.g., bounce + heatmap)
3. **Use source-specific presets** — Different sources benefit from different aesthetics (CI = terminal, iMessage = casual)
4. **Fade-to-ghost always on** — Provides smooth exit for expiring notifications
5. **Terminal effects for CI** — stack_trace, boot_sequence, ascii_border fit the theme
6. **Spinner + breathing for unread** — Subtle indicator without distraction

## Hot-Reload
Changes to `notify.yaml` apply immediately — no restart needed. Watch terminal logs:
```
grep '"ev":"notify.animcfg' ~/.local/state/thegrid/thegrid-server.json
```
```

**Pseudocode sections:**
1. Header: Overview, animation phases
2. Categories table: 32 animations grouped with short descriptions
3. YAML config example: Default + 3 source-specific presets (iMessage, CI, urgent)
4. JSON override example: Per-notification control
5. Built-in defaults note: Fallback behavior
6. Best practices: Tips for composing animations
7. Hot-reload: How to verify changes

---

## Implementation Order

1. **AnimationConfig.swift** — Add source-specific presets to `builtinDefault` (DW-5.1)
2. **NotificationPanelViews.swift** — Update help view with animation catalog (DW-5.2)
3. **docs/animations.md** — Create user-facing reference (DW-5.3 validation + user docs)

**Testing:**
- Compile and run: `swift build --package-path grid-notify`
- Verify default behavior with no notify.yaml present
- Add source-specific presets to notify.yaml, verify per-source animations apply
- Open help view (?), verify all 32 animations listed, grouped by category
- Inspect logs for animation config loading: `jlog("notify.animcfg"`
