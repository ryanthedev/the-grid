package mouse

import (
	"context"
	"fmt"

	"github.com/yourusername/grid-cli/internal/client"
)

// WarpToWindow moves the mouse cursor to the center of the specified window.
// Returns an error if the warp fails.
func WarpToWindow(ctx context.Context, c *client.Client, windowID uint32) error {
	_, err := c.CallMethod(ctx, "mouse.warp", map[string]interface{}{
		"windowId": windowID,
	})
	if err != nil {
		return fmt.Errorf("mouse warp failed: %w", err)
	}
	return nil
}
