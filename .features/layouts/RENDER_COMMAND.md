# Render Command

The `render` command positions multiple windows on a space using a JSON layout configuration. It's useful for creating saved window layouts or tiling configurations.

## JSON Input Format

```json
{
  "windows": [
    {
      "id": 12345,
      "x": 0.0,
      "y": 0.0,
      "width": 0.5,
      "height": 1.0
    }
  ]
}
```

**Coordinates are normalized (0.0 to 1.0)**:
- `x: 0.0` = left edge, `x: 1.0` = right edge
- `y: 0.0` = top edge, `y: 1.0` = bottom edge
- `width: 0.5` = 50% of display width
- `height: 1.0` = 100% of display height

## Usage

```bash
# Apply layout from file
cat layout.json | grid render <space-id>

# Get JSON output
cat layout.json | grid render <space-id> --json
```

## Examples

### Split Screen (50/50)

```json
{
  "windows": [
    {"id": 12345, "x": 0.0, "y": 0.0, "width": 0.5, "height": 1.0},
    {"id": 67890, "x": 0.5, "y": 0.0, "width": 0.5, "height": 1.0}
  ]
}
```

### Three Column Layout

```json
{
  "windows": [
    {"id": 11111, "x": 0.0,  "y": 0.0, "width": 0.33, "height": 1.0},
    {"id": 22222, "x": 0.33, "y": 0.0, "width": 0.34, "height": 1.0},
    {"id": 33333, "x": 0.67, "y": 0.0, "width": 0.33, "height": 1.0}
  ]
}
```

### Main + Sidebar (70/30)

```json
{
  "windows": [
    {"id": 12345, "x": 0.0, "y": 0.0, "width": 0.7, "height": 1.0},
    {"id": 67890, "x": 0.7, "y": 0.0, "width": 0.3, "height": 1.0}
  ]
}
```

## Quick Reference

1. Get window IDs: `grid list windows`
2. Get space ID: `grid list spaces`
3. Create your layout JSON with normalized coordinates
4. Apply: `cat layout.json | grid render <space-id>`
