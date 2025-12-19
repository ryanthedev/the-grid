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
		"enabled": cfg.GetEnabled(),
	}

	// Check for new nested structure (Active/Inactive fields)
	if cfg.Active != nil || cfg.Inactive != nil {
		// Use new nested structure
		if cfg.Active != nil {
			activeConfig := map[string]interface{}{
				"color":        cfg.Active.Color,
				"width":        cfg.Active.Width,
				"cornerRadius": cfg.Active.CornerRadius,
				"opacity":      cfg.Active.Opacity,
			}
			// Add glow fields if present
			if cfg.Active.GlowRadius != nil {
				activeConfig["glowRadius"] = *cfg.Active.GlowRadius
			}
			if cfg.Active.GlowColor != nil {
				activeConfig["glowColor"] = *cfg.Active.GlowColor
			}
			if cfg.Active.GlowOpacity != nil {
				activeConfig["glowOpacity"] = *cfg.Active.GlowOpacity
			}
			if cfg.Active.GlowSpread != nil {
				activeConfig["glowSpread"] = *cfg.Active.GlowSpread
			}
			// Add shadow fields if present
			if cfg.Active.ShadowRadius != nil {
				activeConfig["shadowRadius"] = *cfg.Active.ShadowRadius
			}
			if cfg.Active.ShadowOffset != nil {
				activeConfig["shadowOffset"] = *cfg.Active.ShadowOffset
			}
			if cfg.Active.ShadowColor != nil {
				activeConfig["shadowColor"] = *cfg.Active.ShadowColor
			}
			if cfg.Active.ShadowOpacity != nil {
				activeConfig["shadowOpacity"] = *cfg.Active.ShadowOpacity
			}
			// Add animation if present
			if cfg.Active.Animation != nil {
				activeConfig["animation"] = cfg.Active.Animation
			}
			configParams["active"] = activeConfig
		}

		if cfg.Inactive != nil {
			inactiveConfig := map[string]interface{}{
				"enabled":      cfg.Inactive.Enabled,
				"color":        cfg.Inactive.Color,
				"width":        cfg.Inactive.Width,
				"cornerRadius": cfg.Inactive.CornerRadius,
				"opacity":      cfg.Inactive.Opacity,
			}
			// Add glow fields if present
			if cfg.Inactive.GlowRadius != nil {
				inactiveConfig["glowRadius"] = *cfg.Inactive.GlowRadius
			}
			if cfg.Inactive.GlowColor != nil {
				inactiveConfig["glowColor"] = *cfg.Inactive.GlowColor
			}
			if cfg.Inactive.GlowOpacity != nil {
				inactiveConfig["glowOpacity"] = *cfg.Inactive.GlowOpacity
			}
			if cfg.Inactive.GlowSpread != nil {
				inactiveConfig["glowSpread"] = *cfg.Inactive.GlowSpread
			}
			// Add shadow fields if present
			if cfg.Inactive.ShadowRadius != nil {
				inactiveConfig["shadowRadius"] = *cfg.Inactive.ShadowRadius
			}
			if cfg.Inactive.ShadowOffset != nil {
				inactiveConfig["shadowOffset"] = *cfg.Inactive.ShadowOffset
			}
			if cfg.Inactive.ShadowColor != nil {
				inactiveConfig["shadowColor"] = *cfg.Inactive.ShadowColor
			}
			if cfg.Inactive.ShadowOpacity != nil {
				inactiveConfig["shadowOpacity"] = *cfg.Inactive.ShadowOpacity
			}
			configParams["inactive"] = inactiveConfig
		}
	} else {
		// Fall back to old flat structure for backwards compatibility
		configParams["width"] = cfg.GetWidth()
		configParams["style"] = cfg.GetStyle()
		configParams["corner_radius"] = cfg.GetCornerRadius()
		configParams["padding"] = cfg.GetPadding()
		configParams["hidpi"] = cfg.GetHiDPI()

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
// displayUUID is required for per-display caching in the server
func (c *Client) SendCellAssignments(ctx context.Context, displayUUID string, assignments []CellAssignment, overrides map[string]CellOverride, cellBounds map[string]CellRect) error {
	// Build assignment map (windowID as string -> cellID)
	assignmentMap := make(map[string]string)
	for _, a := range assignments {
		assignmentMap[fmt.Sprintf("%d", a.WindowID)] = a.CellID
	}

	params := map[string]interface{}{
		"assignments": assignmentMap,
		"displayUUID": displayUUID,
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
