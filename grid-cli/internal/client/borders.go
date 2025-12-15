package client

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/config"
)

// SendBorderConfig sends border configuration to the server
func (c *Client) SendBorderConfig(ctx context.Context, cfg *config.BorderConfig) error {
	if cfg == nil || !cfg.GetEnabled() {
		return nil
	}

	configParams := map[string]interface{}{
		"enabled":       cfg.GetEnabled(),
		"width":         cfg.GetWidth(),
		"style":         cfg.GetStyle(),
		"corner_radius": cfg.GetCornerRadius(),
		"padding":       cfg.GetPadding(),
		"hidpi":         cfg.GetHiDPI(),
	}

	// Add optional color fields if set
	if cfg.ActiveWindowColor != nil {
		configParams["active_window_color"] = *cfg.ActiveWindowColor
	}
	if cfg.ActiveCellColor != nil {
		configParams["active_cell_color"] = *cfg.ActiveCellColor
	}
	if cfg.InactiveColor != nil {
		configParams["inactive_color"] = *cfg.InactiveColor
	}

	// Add palette if set
	if len(cfg.Palette) > 0 {
		configParams["palette"] = cfg.Palette
	}

	// Add blacklist/whitelist if set
	if len(cfg.Blacklist) > 0 {
		configParams["blacklist"] = cfg.Blacklist
	}
	if len(cfg.Whitelist) > 0 {
		configParams["whitelist"] = cfg.Whitelist
	}

	// Wrap config in params["config"] as expected by server
	params := map[string]interface{}{
		"config": configParams,
	}

	resp, err := c.request(ctx, "borders.configure", params)
	if err != nil {
		return fmt.Errorf("failed to send border config: %w", err)
	}

	if resp.IsError() {
		return fmt.Errorf("server error: %s", resp.GetError())
	}

	return nil
}

// CellAssignment represents a window-to-cell mapping
type CellAssignment struct {
	WindowID uint32
	CellID   string
}

// CellRect represents the bounds of a cell
type CellRect struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// CellOverride represents per-cell border config
type CellOverride struct {
	ActiveCellColor string `json:"activeCellColor,omitempty"`
	InactiveColor   string `json:"inactiveColor,omitempty"`
	Style           string `json:"style,omitempty"`
}

// SendCellAssignments sends window-to-cell mappings to the server
func (c *Client) SendCellAssignments(ctx context.Context, assignments []CellAssignment, overrides map[string]CellOverride, cellBounds map[string]CellRect) error {
	// Build assignment map (windowID as string -> cellID)
	assignmentMap := make(map[string]string)
	for _, a := range assignments {
		assignmentMap[fmt.Sprintf("%d", a.WindowID)] = a.CellID
	}

	params := map[string]interface{}{
		"assignments": assignmentMap,
	}

	// Add overrides if provided
	if len(overrides) > 0 {
		// Convert overrides to map[string]interface{} for JSON serialization
		cellsMap := make(map[string]interface{})
		for cellID, override := range overrides {
			cellConfig := make(map[string]interface{})
			if override.ActiveCellColor != "" {
				cellConfig["activeCellColor"] = override.ActiveCellColor
			}
			if override.InactiveColor != "" {
				cellConfig["inactiveColor"] = override.InactiveColor
			}
			if override.Style != "" {
				cellConfig["style"] = override.Style
			}
			cellsMap[cellID] = cellConfig
		}
		params["cells"] = cellsMap
	}

	// Add cellBounds if provided
	if len(cellBounds) > 0 {
		params["cellBounds"] = cellBounds
	}

	resp, err := c.request(ctx, "borders.setCellAssignments", params)
	if err != nil {
		return fmt.Errorf("failed to send cell assignments: %w", err)
	}

	if resp.IsError() {
		return fmt.Errorf("server error: %s", resp.GetError())
	}

	return nil
}
