package server

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/types"
)

// Snapshot is a parsed, read-only view of server state at a point in time.
// It contains everything needed to reconcile local state and execute commands.
type Snapshot struct {
	SpaceID       string            // Current active space ID
	DisplayBounds types.Rect        // Visible frame for layout calculations
	Windows       []WindowInfo      // All tileable windows on current space
	WindowIDs     map[uint32]bool   // Quick lookup: does window exist?
}

// WindowInfo contains window data needed for layout operations.
type WindowInfo struct {
	ID        uint32
	AppName   string
	BundleID  string
	Title     string
	Frame     types.Rect
	Level     int
	IsMinimized bool
	IsHidden    bool
}

// IsTileable returns true if the window should be included in tiling.
func (w WindowInfo) IsTileable() bool {
	return !w.IsMinimized && !w.IsHidden && w.Level == 0
}

// Fetch calls dump ONCE and parses into a Snapshot.
func Fetch(ctx context.Context, c *client.Client) (*Snapshot, error) {
	raw, err := c.Dump(ctx)
	if err != nil {
		return nil, fmt.Errorf("dump failed: %w", err)
	}
	return parseSnapshot(raw)
}

func parseSnapshot(raw map[string]interface{}) (*Snapshot, error) {
	snap := &Snapshot{
		WindowIDs: make(map[uint32]bool),
	}

	// 1. Find current active space
	snap.SpaceID = findActiveSpaceID(raw)

	// 2. Get display bounds for the active space
	bounds, err := findDisplayBounds(raw, snap.SpaceID)
	if err != nil {
		return nil, fmt.Errorf("failed to get display bounds: %w", err)
	}
	snap.DisplayBounds = bounds

	// 3. Parse and filter windows for the active space
	snap.Windows = parseWindows(raw, snap.SpaceID)

	// 4. Build window ID lookup map (only tileable windows)
	for _, w := range snap.Windows {
		if w.IsTileable() {
			snap.WindowIDs[w.ID] = true
		}
	}

	return snap, nil
}

func findActiveSpaceID(raw map[string]interface{}) string {
	// Try displays first - find the display with the active space
	displays, ok := raw["displays"].([]interface{})
	if ok {
		for _, d := range displays {
			display, ok := d.(map[string]interface{})
			if !ok {
				continue
			}
			if currentSpaceID := display["currentSpaceID"]; currentSpaceID != nil {
				return fmt.Sprintf("%v", interfaceToInt(currentSpaceID))
			}
		}
	}

	// Fallback to spaces - find the active one
	spaces, ok := raw["spaces"].(map[string]interface{})
	if ok {
		for _, s := range spaces {
			space, ok := s.(map[string]interface{})
			if !ok {
				continue
			}
			if isActive, ok := space["isActive"].(bool); ok && isActive {
				if id := space["id"]; id != nil {
					return fmt.Sprintf("%v", interfaceToInt(id))
				}
			}
		}
	}

	// Last resort fallback
	return "1"
}

func findDisplayBounds(raw map[string]interface{}, spaceID string) (types.Rect, error) {
	displays, ok := raw["displays"].([]interface{})
	if !ok {
		return types.Rect{}, fmt.Errorf("no displays in state")
	}

	for _, d := range displays {
		display, ok := d.(map[string]interface{})
		if !ok {
			continue
		}

		// Try visibleFrame first (excludes menu bar and dock)
		if rect, ok := parseFrame(display["visibleFrame"]); ok {
			return rect, nil
		}

		// Fallback to regular frame
		if rect, ok := parseFrame(display["frame"]); ok {
			return rect, nil
		}
	}

	return types.Rect{}, fmt.Errorf("no display bounds found")
}

func parseWindows(raw map[string]interface{}, spaceID string) []WindowInfo {
	var windows []WindowInfo

	rawWindows, ok := raw["windows"].(map[string]interface{})
	if !ok {
		// Try as array
		if rawArr, ok := raw["windows"].([]interface{}); ok {
			for _, w := range rawArr {
				if win := parseWindow(w, spaceID); win != nil {
					windows = append(windows, *win)
				}
			}
		}
		return windows
	}

	for _, w := range rawWindows {
		if win := parseWindow(w, spaceID); win != nil {
			windows = append(windows, *win)
		}
	}

	return windows
}

func parseWindow(w interface{}, spaceID string) *WindowInfo {
	win, ok := w.(map[string]interface{})
	if !ok {
		return nil
	}

	// Skip windows with no app name (system UI elements)
	appName := toString(win["appName"])
	if appName == "" {
		return nil
	}

	// Check if window is on this space
	spaces, ok := win["spaces"].([]interface{})
	if ok {
		onSpace := false
		for _, s := range spaces {
			spaceVal := fmt.Sprintf("%v", interfaceToInt(s))
			if spaceVal == spaceID {
				onSpace = true
				break
			}
		}
		if !onSpace {
			return nil
		}
	}

	// Build WindowInfo
	window := WindowInfo{
		ID:          uint32(toFloat64(win["id"])),
		Title:       toString(win["title"]),
		AppName:     appName,
		BundleID:    toString(win["bundleId"]),
		IsMinimized: toBool(win["isMinimized"]),
		IsHidden:    toBool(win["isHidden"]),
		Level:       int(toFloat64(win["level"])),
	}

	// Parse frame
	if rect, ok := parseFrame(win["frame"]); ok {
		window.Frame = rect
	}

	return &window
}

// parseFrame handles both object format {x,y,width,height} and array format [[x,y],[w,h]]
func parseFrame(frame interface{}) (types.Rect, bool) {
	if frame == nil {
		return types.Rect{}, false
	}

	// Try object format: {x, y, width, height}
	if obj, ok := frame.(map[string]interface{}); ok {
		return types.Rect{
			X:      toFloat64(obj["x"]),
			Y:      toFloat64(obj["y"]),
			Width:  toFloat64(obj["width"]),
			Height: toFloat64(obj["height"]),
		}, true
	}

	// Try array format: [[x, y], [width, height]]
	if arr, ok := frame.([]interface{}); ok && len(arr) == 2 {
		origin, okOrigin := arr[0].([]interface{})
		size, okSize := arr[1].([]interface{})

		if okOrigin && okSize && len(origin) >= 2 && len(size) >= 2 {
			return types.Rect{
				X:      toFloat64(origin[0]),
				Y:      toFloat64(origin[1]),
				Width:  toFloat64(size[0]),
				Height: toFloat64(size[1]),
			}, true
		}
	}

	return types.Rect{}, false
}

// Type conversion helpers

func toFloat64(v interface{}) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case float32:
		return float64(n)
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case int32:
		return float64(n)
	default:
		return 0
	}
}

func toString(v interface{}) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func toBool(v interface{}) bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return false
}

func interfaceToInt(v interface{}) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int:
		return int64(n)
	case int64:
		return n
	case int32:
		return int64(n)
	default:
		return 0
	}
}
