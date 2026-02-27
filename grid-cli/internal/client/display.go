package client

import (
	"context"
	"fmt"
)

// DisplayInfo represents a connected display
type DisplayInfo struct {
	UUID           string
	Name           string
	Frame          DisplayRect
	VisibleFrame   DisplayRect
	CurrentSpaceID string
	IsMain         bool
	ScaleFactor    float64
}

// DisplayRect represents a rectangle with origin and size
type DisplayRect struct {
	X, Y, Width, Height float64
}

// GetMetadata returns cached server metadata without window enumeration
func (c *Client) GetMetadata(ctx context.Context) (map[string]interface{}, error) {
	return c.CallMethod(ctx, "metadata.get", nil)
}

// GetActiveDisplay returns the display containing the currently focused window
func (c *Client) GetActiveDisplay(ctx context.Context) (*DisplayInfo, error) {
	result, err := c.CallMethod(ctx, "display.get", map[string]interface{}{
		"active": true,
	})
	if err != nil {
		return nil, err
	}
	return parseDisplayInfo(result)
}

// GetDisplays returns all connected displays
func (c *Client) GetDisplays(ctx context.Context) ([]DisplayInfo, error) {
	result, err := c.CallMethod(ctx, "display.list", nil)
	if err != nil {
		return nil, err
	}

	displaysRaw, ok := result["displays"].([]interface{})
	if !ok {
		return nil, fmt.Errorf("invalid displays response")
	}

	displays := make([]DisplayInfo, 0, len(displaysRaw))
	for _, d := range displaysRaw {
		dm, ok := d.(map[string]interface{})
		if !ok {
			continue
		}
		info, err := parseDisplayInfo(dm)
		if err != nil {
			continue
		}
		displays = append(displays, *info)
	}
	return displays, nil
}

// FindWindow searches for a window by app name and/or title.
// Returns windowId, pid, found, error.
func (c *Client) FindWindow(ctx context.Context, appName, title string) (uint32, int, bool, error) {
	params := map[string]interface{}{}
	if appName != "" {
		params["appName"] = appName
	}
	if title != "" {
		params["title"] = title
	}

	result, err := c.CallMethod(ctx, "window.find", params)
	if err != nil {
		return 0, 0, false, err
	}

	found, _ := result["found"].(bool)
	if !found {
		return 0, 0, false, nil
	}

	widStr := toString(result["windowId"])
	wid := toUint32(widStr)
	pid := toInt(result["pid"])

	return wid, pid, true, nil
}

func parseDisplayInfo(m map[string]interface{}) (*DisplayInfo, error) {
	uuid := toString(m["uuid"])
	if uuid == "" {
		return nil, fmt.Errorf("missing uuid")
	}

	return &DisplayInfo{
		UUID:           uuid,
		Name:           toString(m["name"]),
		Frame:          parseRect(m["frame"]),
		VisibleFrame:   parseRect(m["visibleFrame"]),
		CurrentSpaceID: toString(m["currentSpaceID"]),
		IsMain:         toBool(m["isMain"]),
		ScaleFactor:    toFloat64(m["backingScaleFactor"], 1.0),
	}, nil
}

func parseRect(v interface{}) DisplayRect {
	m, ok := v.(map[string]interface{})
	if !ok {
		return DisplayRect{}
	}
	return DisplayRect{
		X:      toFloat64(m["x"], 0),
		Y:      toFloat64(m["y"], 0),
		Width:  toFloat64(m["width"], 0),
		Height: toFloat64(m["height"], 0),
	}
}

func toFloat64(v interface{}, def float64) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case float32:
		return float64(n)
	case int:
		return float64(n)
	case int64:
		return float64(n)
	default:
		return def
	}
}

func toString(v interface{}) string {
	s, _ := v.(string)
	return s
}

func toBool(v interface{}) bool {
	b, _ := v.(bool)
	return b
}

func toUint32(s string) uint32 {
	var n uint32
	fmt.Sscanf(s, "%d", &n)
	return n
}

func toInt(v interface{}) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case int64:
		return int(n)
	default:
		return 0
	}
}
