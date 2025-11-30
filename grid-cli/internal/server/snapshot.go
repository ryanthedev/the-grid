package server

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/types"
)

// DisplayInfo contains display metadata for cross-monitor navigation
type DisplayInfo struct {
	UUID           string
	Frame          types.Rect  // Full screen bounds in global Quartz coordinates
	VisibleFrame   types.Rect  // Excludes menu bar/dock
	CurrentSpaceID interface{} // Can be int, float64, or bool (for overflow)
	IsMain         bool
}

// Snapshot is a parsed, read-only view of server state at a point in time.
// It contains everything needed to reconcile local state and execute commands.
type Snapshot struct {
	SpaceID         string            // Current active space ID
	DisplayBounds   types.Rect        // Visible frame for layout calculations
	Windows         []WindowInfo      // All tileable windows on current space
	WindowIDs       map[uint32]bool   // Quick lookup: does window exist?
	FocusedWindowID uint32            // OS-focused window ID (from metadata)
	AllDisplays     []DisplayInfo     // All connected displays with global frames
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

	// 1. Get active display UUID first - this determines everything else
	activeDisplayUUID, err := getActiveDisplayUUID(raw)
	if err != nil {
		return nil, fmt.Errorf("failed to get active display: %w", err)
	}

	// 2. Find current active space using the display UUID
	spaceID, err := findActiveSpaceID(raw, activeDisplayUUID)
	if err != nil {
		return nil, fmt.Errorf("failed to determine active space: %w", err)
	}
	snap.SpaceID = spaceID

	// 3. Get display bounds for the ACTIVE display (not first display!)
	bounds, err := findDisplayBounds(raw, activeDisplayUUID)
	if err != nil {
		return nil, fmt.Errorf("failed to get display bounds: %w", err)
	}
	snap.DisplayBounds = bounds

	// 4. Parse and filter windows for the active space
	snap.Windows = parseWindows(raw, snap.SpaceID)

	// 5. Build window ID lookup map (only tileable windows)
	for _, w := range snap.Windows {
		if w.IsTileable() {
			snap.WindowIDs[w.ID] = true
		}
	}

	// 6. Get focused window ID from metadata
	snap.FocusedWindowID = parseFocusedWindowID(raw)

	// 7. Parse all displays for cross-monitor navigation
	snap.AllDisplays = parseAllDisplays(raw)

	return snap, nil
}

func parseFocusedWindowID(raw map[string]interface{}) uint32 {
	metadata, ok := raw["metadata"].(map[string]interface{})
	if !ok {
		return 0
	}
	return uint32(toFloat64(metadata["focusedWindowID"]))
}

// parseAllDisplays extracts information about all connected displays
func parseAllDisplays(raw map[string]interface{}) []DisplayInfo {
	displays, ok := raw["displays"].([]interface{})
	if !ok || len(displays) == 0 {
		return nil
	}

	var allDisplays []DisplayInfo

	for _, d := range displays {
		display, ok := d.(map[string]interface{})
		if !ok {
			continue
		}

		// Extract UUID (required)
		uuid, ok := display["uuid"].(string)
		if !ok || uuid == "" {
			continue
		}

		displayInfo := DisplayInfo{
			UUID:           uuid,
			CurrentSpaceID: display["currentSpaceID"], // Keep as interface{} for overflow handling
			IsMain:         toBool(display["isMain"]),
		}

		// Parse frame (full screen bounds)
		if rect, ok := parseFrame(display["frame"]); ok {
			displayInfo.Frame = rect
		}

		// Parse visibleFrame (excludes menu bar/dock)
		if rect, ok := parseFrame(display["visibleFrame"]); ok {
			displayInfo.VisibleFrame = rect
		}

		allDisplays = append(allDisplays, displayInfo)
	}

	return allDisplays
}

// getActiveDisplayUUID extracts the active display UUID from server metadata.
func getActiveDisplayUUID(raw map[string]interface{}) (string, error) {
	metadata, ok := raw["metadata"].(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("missing metadata in server state")
	}

	activeDisplayUUID, ok := metadata["activeDisplayUUID"].(string)
	if !ok || activeDisplayUUID == "" {
		return "", fmt.Errorf("missing activeDisplayUUID in metadata")
	}

	return activeDisplayUUID, nil
}

// findActiveSpaceID finds the current space ID for the given active display.
func findActiveSpaceID(raw map[string]interface{}, activeDisplayUUID string) (string, error) {
	displays, ok := raw["displays"].([]interface{})
	if !ok || len(displays) == 0 {
		return "", fmt.Errorf("no displays in server state")
	}

	for _, d := range displays {
		display, ok := d.(map[string]interface{})
		if !ok {
			continue
		}

		uuid, ok := display["uuid"].(string)
		if !ok || uuid != activeDisplayUUID {
			continue
		}

		currentSpaceID := display["currentSpaceID"]
		if currentSpaceID == nil {
			return "", fmt.Errorf("active display %s has no currentSpaceID", activeDisplayUUID)
		}

		return fmt.Sprintf("%v", interfaceToInt(currentSpaceID)), nil
	}

	return "", fmt.Errorf("active display %s not found", activeDisplayUUID)
}

// findDisplayBounds finds the visible frame for the given active display.
func findDisplayBounds(raw map[string]interface{}, activeDisplayUUID string) (types.Rect, error) {
	displays, ok := raw["displays"].([]interface{})
	if !ok || len(displays) == 0 {
		return types.Rect{}, fmt.Errorf("no displays in server state")
	}

	for _, d := range displays {
		display, ok := d.(map[string]interface{})
		if !ok {
			continue
		}

		uuid, ok := display["uuid"].(string)
		if !ok || uuid != activeDisplayUUID {
			continue
		}

		// Found the active display - get its bounds
		if rect, ok := parseFrame(display["visibleFrame"]); ok {
			return rect, nil
		}
		if rect, ok := parseFrame(display["frame"]); ok {
			return rect, nil
		}

		return types.Rect{}, fmt.Errorf("active display %s has no frame data", activeDisplayUUID)
	}

	return types.Rect{}, fmt.Errorf("active display %s not found", activeDisplayUUID)
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
