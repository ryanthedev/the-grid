# GridNotify Animation Catalog

## Overview

GridNotify includes 32 built-in animations that enhance notification presentation. Animations are grouped by category and run simultaneously during their active phases. Control which animations are active via YAML presets per source or per-notification JSON overrides.

## Animation Phases

Every notification transitions through distinct lifecycle phases, each with its own active animations:

- **arrival** — First 2 seconds after notification appears. Typically use entrance animations (matrix_title, slide_in, bounce).
- **idle** — After arrival until either the warning threshold approaches or the notification expires. Use subtle animations (wave_title, spinner, heartbeat).
- **warning** — Active during the warning phase (last `warnBefore` seconds before expiry). Use urgent indicators (shake, progress_bar, glitch, border_strobe).
- **ghost** — Last 3 seconds before automatic expiry. Use exit animations (fade_to_ghost, dissolve, breathing stops).

## Categories & Animations

### Text Animations (7)

Text effects modify how notification titles and bodies are displayed.

1. **matrix_title**
   - Characters resolve from random glyphs on arrival
   - Active during: arrival
   - Effect: Title text appears with a cascading resolve effect, each character "landing" into place

2. **wave_title**
   - Wavy vertical motion applied to title text
   - Active during: idle (unread notifications only)
   - Effect: Title letter heights oscillate smoothly, like waves

3. **glitch**
   - Random character substitution at brief intervals
   - Active during: warning
   - Effect: Title corrupts with random characters, then corrects, creating instability

4. **redact**
   - Text reveals from block characters (█) over time
   - Active during: arrival
   - Effect: Notification body appears as redacted (block characters), then reveals real text

5. **typing_indicator**
   - Reveals text one character at a time at natural typing speed
   - Active during: arrival
   - Effect: Body text appears character-by-character, like a typewriter

6. **cursor_blink**
   - Blinking block cursor at end of title
   - Active during: idle (unread notifications only)
   - Effect: Visual indicator that there's new content; cursor blinks at title end

7. **chromatic_aberration**
   - RGB color channels split slightly on title
   - Active during: warning
   - Effect: Title text shows red, green, blue channels offset, creating a glitch/damage aesthetic

### Spatial Animations (6)

Spatial effects modify notification layout, position, and scale.

1. **slide_in**
   - Notification slides in from top of panel
   - Active during: arrival
   - Effect: Entry motion from top edge to resting position

2. **bounce**
   - Elastic bounce on arrival
   - Active during: arrival
   - Effect: Notification overshoots height then settles with a spring animation

3. **accordion**
   - Expands from zero height to full height
   - Active during: arrival
   - Effect: Notification grows vertically from collapsed state, like opening an accordion

4. **tilt**
   - 3D perspective rotation when notification is selected
   - Active during: selection only
   - Effect: Subtle 3D tilt away from viewer when highlighted

5. **parallax**
   - Title and body move at different scroll speeds during list scrolling
   - Active during: idle/warning (when scrolled)
   - Effect: Depth perception; title stays higher than body during scroll

6. **scanline**
   - Horizontal line sweeps across notification continuously
   - Active during: all phases
   - Effect: CRT monitor scanline effect moves left to right repeatedly

### Color & Mood Animations (3)

Color effects modify notification appearance through tinting or chromatic changes.

1. **gradient_sweep**
   - Accent color washes left to right across notification
   - Active during: arrival
   - Effect: Accent color sweeps horizontally, highlighting the notification as it arrives

2. **heatmap**
   - Background tint shifts from cool to warm based on notification age
   - Active during: idle/warning
   - Effect: Older notifications shift from neutral to warm orange/red, visually indicating age

3. **neon_flicker**
   - Border randomly dims and brightens
   - Active during: idle/warning (urgent priority only)
   - Effect: Border glows with neon flicker, like retro signage; adds urgency

### Progress Animations (4)

Progress effects indicate time remaining or lifecycle stage.

1. **hourglass_sprite**
   - Animated hourglass sprite frames change based on TTL (time-to-live) progress
   - Active during: idle/warning (if TTL > 0)
   - Effect: Hourglass animation advances as notification ages; visual countdown

2. **pie_countdown**
   - Shrinking pie chart in the time indicator during warning
   - Active during: warning
   - Effect: Pie chart visually represents remaining time; shrinks to zero at expiry

3. **heartbeat**
   - Row scales up 2% then back down periodically
   - Active during: idle (unread notifications only)
   - Effect: Notification "pulses" like a heartbeat, indicating new unread content

4. **progress_bar**
   - Horizontal drain bar below title during warning
   - Active during: warning
   - Effect: Bar shrinks left-to-right as warning time countdown progresses

### Terminal & Lifecycle Animations (12)

Terminal/lifecycle effects are inspired by command-line interfaces and signal lifecycle transitions.

1. **shake**
   - Horizontal rapid oscillation
   - Active during: warning
   - Effect: Notification shakes left-right, emphasizing urgency

2. **grow**
   - Extra vertical padding added
   - Active during: warning
   - Effect: Row expands vertically, taking up more visual space

3. **warning_pulse**
   - Pulsing overlay of urgent color (dim to bright)
   - Active during: warning
   - Effect: Notification background pulses with urgent color behind text

4. **border_strobe**
   - Left edge bar strobes between urgent and accent color
   - Active during: warning
   - Effect: 2-3px bar at left flickers colors to draw attention

5. **spinner**
   - Animated braille spinner in left margin (unread), or fast countdown spinner (warning)
   - Active during: idle (unread) and warning
   - Effect: Spinning animation indicates pending action; changes speed in warning phase

6. **breathing**
   - Spinner glows with pulsing opacity (like Mac sleep LED)
   - Active during: arrival, idle, ghost
   - Effect: Spinner fades in/out smoothly, subtle animation

7. **fade_to_ghost**
   - Notification fades to lower opacity in final 3 seconds
   - Active during: ghost
   - Effect: Notification becomes translucent as it expires, gentle exit

8. **dissolve**
   - Random characters are replaced with noise as notification expires
   - Active during: ghost
   - Effect: Notification degrades into visual noise before disappearing

9. **ascii_border**
   - Box-drawing characters (┌─┐│└┘) draw a border around selected notification
   - Active during: selection
   - Effect: ASCII box highlights selected notification in terminal style

10. **boot_sequence**
    - Terminal boot animation sequence plays when notification panel first appears (once per session)
    - Active during: panel startup (not persisted across launches)
    - Effect: Sequence of terminal-style text appears on screen refresh, establishing terminal aesthetic

11. **stack_trace**
    - Warning phase notification formatted like a terminal stack trace with line numbers
    - Active during: warning
    - Effect: Title becomes line number, body becomes error message with indentation

12. **arrival_flash**
    - Accent color overlay flash on arrival
    - Active during: arrival
    - Effect: Brief bright overlay (0.8s) highlights the new notification

## Configuration

### Default Presets

If no `notify.yaml` file exists or no `animations` section is present, GridNotify uses built-in defaults that match the original pre-engine behavior:

```yaml
# Built-in defaults (used when notify.yaml is missing)
animations:
  default:
    arrival: [slide_in, matrix_title, arrival_flash, fade_to_ghost, spinner, breathing]
    idle: [wave_title, spinner, breathing, fade_to_ghost]
    warning: [shake, grow, border_strobe, warning_pulse, progress_bar, spinner, fade_to_ghost]
    ghost: [fade_to_ghost, wave_title, spinner, breathing]
```

### YAML Configuration

Location: `~/.config/thegrid/notify.yaml`

Define default animations and source-specific presets:

```yaml
animations:
  default:
    arrival: [slide_in, matrix_title, arrival_flash, spinner, breathing]
    idle: [wave_title, spinner, breathing, fade_to_ghost]
    warning: [shake, grow, border_strobe, warning_pulse, progress_bar, spinner, fade_to_ghost]
    ghost: [fade_to_ghost]

  sources:
    imessage:
      arrival: [slide_in, matrix_title, arrival_flash, fade_to_ghost, spinner, breathing, bounce]
      idle: [wave_title, spinner, breathing, fade_to_ghost]
      warning: [glitch, shake, progress_bar, spinner, fade_to_ghost]
      ghost: [fade_to_ghost]

    generic:
      arrival: [slide_in, matrix_title, arrival_flash, fade_to_ghost, spinner, breathing]
      idle: [wave_title, spinner, breathing, fade_to_ghost]
      warning: [shake, grow, border_strobe, warning_pulse, progress_bar, spinner, fade_to_ghost]
      ghost: [fade_to_ghost]

    ci:
      arrival: [slide_in, boot_sequence, spinner, breathing]
      idle: [spinner, breathing]
      warning: [stack_trace, progress_bar, shake, spinner]
      ghost: [fade_to_ghost]

    urgent:
      arrival: [slide_in, neon_flicker, spinner, breathing]
      idle: [heartbeat, spinner, breathing, fade_to_ghost]
      warning: [dissolve, warning_pulse, progress_bar, spinner, fade_to_ghost]
      ghost: [fade_to_ghost]
```

**Structure:**
- `default` — Fallback preset for all sources without explicit overrides
- `sources` — Source-specific presets, keyed by notification source string (e.g., "ci", "imessage")
- Each preset can define: `arrival`, `idle`, `warning`, `ghost` (list of animation names)
- Missing phase keys default to empty (no animations for that phase)

### Per-Notification JSON Override

Override animations for a specific notification via JSON payload:

```json
{
  "title": "Build failed",
  "body": "main branch test suite failure",
  "source": "ci",
  "priority": "urgent",
  "animations": {
    "arrival": ["stack_trace", "boot_sequence"],
    "idle": ["spinner"],
    "warning": ["glitch", "progress_bar", "shake"],
    "ghost": ["dissolve"]
  }
}
```

**Priority:**
1. Per-notification `animations` field (highest priority)
2. Source-specific preset from `notify.yaml`
3. Default preset from `notify.yaml` or built-in default (lowest priority)

### Hot-Reload

Changes to `~/.config/thegrid/notify.yaml` apply immediately — no restart required.

Verify changes in logs:

```bash
grep '"ev":"notify.animcfg' ~/.local/state/thegrid/thegrid-server.json | tail -5
```

Expected output: `notify.animcfg.reload` event when config changes.

## Best Practices

### 1. Don't Mix Too Many Text Effects

Text animations compete for the title space. Avoid enabling multiple text effects simultaneously:

**Good:**
```yaml
arrival: [slide_in, matrix_title, spinner]  # One text effect (matrix_title)
warning: [glitch, shake, progress_bar]      # One text effect (glitch)
```

**Avoid:**
```yaml
arrival: [slide_in, matrix_title, redact, typing_indicator, spinner]  # Too many
```

### 2. Stack Spatial + Color Effects

Spatial and color effects compose well together without competing:

**Good:**
```yaml
arrival: [bounce, gradient_sweep, spinner]  # Spatial + color + progress
```

### 3. Use Source-Specific Presets

Different notification sources benefit from different aesthetics:

- **iMessage:** Casual, friendly (bounce, wave_title, glitch)
- **CI/Build:** Terminal, technical (boot_sequence, stack_trace, progress_bar)
- **Urgent:** High-priority (neon_flicker, dissolve, warning_pulse)
- **Generic:** Conservative default (wave_title, shake, progress_bar)

### 4. Keep Fade-to-Ghost Always On

Always include `fade_to_ghost` in your presets (especially `ghost` phase) to provide a smooth exit animation:

```yaml
ghost: [fade_to_ghost]  # Essential for smooth expiry
```

### 5. Terminal Effects for CI Notifications

If you receive CI/build notifications, use terminal-themed animations:

```yaml
ci:
  arrival: [boot_sequence, spinner]           # Terminal boot
  warning: [stack_trace, progress_bar, shake] # Error format
  ghost: [fade_to_ghost]                      # Smooth exit
```

### 6. Spinner + Breathing for Unread

The spinner (animated braille characters) paired with breathing (pulsing opacity) provides a subtle, non-intrusive indicator of unread notifications:

```yaml
idle: [spinner, breathing, wave_title]  # Quiet unread indicator
```

## Examples

### Minimalist Setup

Show only the most essential animations:

```yaml
animations:
  default:
    arrival: [slide_in, spinner]
    idle: [spinner]
    warning: [shake, progress_bar]
    ghost: [fade_to_ghost]
```

### Eye-Catching Setup

Maximize visual impact with multiple layers:

```yaml
animations:
  default:
    arrival: [slide_in, bounce, gradient_sweep, matrix_title, spinner, breathing]
    idle: [wave_title, heatmap, heartbeat, spinner, breathing]
    warning: [glitch, shake, grow, border_strobe, warning_pulse, progress_bar, spinner, dissolve]
    ghost: [fade_to_ghost, dissolve]
```

### Terminal Aesthetic

Use only terminal/ASCII effects:

```yaml
animations:
  default:
    arrival: [slide_in, ascii_border, spinner]
    idle: [spinner, breathing]
    warning: [stack_trace, border_strobe, shake, progress_bar]
    ghost: [ascii_border, fade_to_ghost]
```

## Troubleshooting

### Animations Not Applying

1. **Verify YAML syntax** — Use `yamllint notify.yaml` or paste into [YAML validator](https://www.yamllint.com/)
2. **Check file location** — Must be `~/.config/thegrid/notify.yaml`
3. **Restart or hot-reload** — Changes apply immediately; if not, check logs for parse errors
4. **View merged config** — See what GridNotify loaded: Check server logs for `notify.animcfg` events

### Performance Issues

If animations cause lag:

1. **Reduce simultaneous effects** — Disable heavy effects like scanline, chromatic_aberration
2. **Per-source tuning** — Use minimal animations for high-volume sources (e.g., CI notifications)
3. **Disable boot_sequence** — Terminal boot animation can be expensive; remove from `arrival` if needed

### Animation Not Visible

1. **Verify it's active for the phase** — Check YAML, ensure animation is in arrival/idle/warning/ghost list
2. **Check notification source** — Verify `source` field matches a configured preset or uses `default`
3. **Check lifecycle phase** — Some animations only appear in specific phases (e.g., progress_bar only in warning)

## Animation Internals

### Registry

All animations are registered at startup via `AnimationRegistry.shared.registerBuiltins()`. Each animation conforms to the `AnimationEffect` protocol with a unique `name` string.

### Resolution Logic

When a notification is rendered, the active animations for its current phase are determined by:

```
active_animations =
  notification.animationOverride[phase] OR
  sourcePresets[notification.source][phase] OR
  defaultPreset[phase]
```

Only animations that are both (1) in the active list and (2) registered in the registry are applied.

### View Integration

Each animation is checked via `isAnimationActive()` in `NotificationItemView`. The view applies relevant ViewModifiers based on active animations. Some animations with state (e.g., `warning_pulse`, `flashOpacity`) are managed inline via `@State` properties.

## Version Info

- **Animations:** 32 built-in effects (Phases 1–4)
- **Config format:** YAML (with optional per-notification JSON override)
- **Hot-reload:** Yes (file watcher on notify.yaml)
- **Fallback:** Built-in defaults match original pre-engine behavior
