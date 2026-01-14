package client

import (
	"context"
	"fmt"

	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/types"
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
	WindowID  uint32
	CellID    string
	StackMode string // "tabs", "vertical", "horizontal"
}

// CellRect represents the bounds of a cell
type CellRect struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// SendCellAssignmentsOpts contains optional parameters for SendCellAssignments.
type SendCellAssignmentsOpts struct {
	FocusedWindowID *uint32
	DisplayFrame    *types.Rect
	WindowOrder     map[string][]uint32 // cellID -> ordered window IDs
}

// SendCellAssignments sends window-to-cell mappings to the server.
// displayUUID is required for per-display caching in the server.
// opts.FocusedWindowID - if provided, server updates focus atomically with assignments.
// opts.DisplayFrame - if provided, server uses for stack indicator edge calculation.
func (c *Client) SendCellAssignments(ctx context.Context, displayUUID string, assignments []CellAssignment, opts *SendCellAssignmentsOpts) error {
	// Build assignment map (windowID as string -> cellID)
	assignmentMap := make(map[string]string)
	// Build stackMode map (cellID -> stackMode)
	stackModeMap := make(map[string]string)
	for _, a := range assignments {
		assignmentMap[fmt.Sprintf("%d", a.WindowID)] = a.CellID
		if a.StackMode != "" {
			stackModeMap[a.CellID] = a.StackMode
		}
	}

	params := map[string]interface{}{
		"assignments":    assignmentMap,
		"displayUUID":    displayUUID,
		"cellStackModes": stackModeMap,
	}

	if opts != nil {
		// Include focused window for atomic update (prevents race conditions)
		if opts.FocusedWindowID != nil {
			params["focusedWindowId"] = *opts.FocusedWindowID
		}
		// Include display frame for stack indicator edge calculation
		if opts.DisplayFrame != nil {
			params["displayFrame"] = map[string]interface{}{
				"x":      opts.DisplayFrame.X,
				"y":      opts.DisplayFrame.Y,
				"width":  opts.DisplayFrame.Width,
				"height": opts.DisplayFrame.Height,
			}
		}
		// Include window order for stack indicator position
		if opts.WindowOrder != nil {
			params["windowOrder"] = opts.WindowOrder
		}
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

// DebugBorders triggers a visual test that cycles the active border through colors.
func (c *Client) DebugBorders(ctx context.Context) error {
	resp, err := c.request(ctx, "borders.debug", map[string]interface{}{})
	if err != nil {
		return fmt.Errorf("failed to trigger border debug: %w", err)
	}
	if resp.IsError() {
		return fmt.Errorf("server error: %s", resp.GetError())
	}
	return nil
}

// SendBorderFocus notifies the server which window is now focused.
// This triggers border updates for focus changes within a cell.
// displayUUID is required so server knows which display's borders to update.
func (c *Client) SendBorderFocus(ctx context.Context, displayUUID string, windowID uint32) error {
	params := map[string]interface{}{
		"windowId":    windowID,
		"displayUUID": displayUUID,
	}

	resp, err := c.request(ctx, "borders.updateFocus", params)
	if err != nil {
		return fmt.Errorf("failed to send border focus: %w", err)
	}

	if resp.IsError() {
		return fmt.Errorf("server error: %s", resp.GetError())
	}

	return nil
}
