package record

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/ryanthedev/grid-cli/internal/types"
)

// BuildCaptureArgs constructs screencapture arguments for a region capture.
func BuildCaptureArgs(region types.Rect, duration int, cursor bool, outPath string) []string {
	args := []string{"-v"}

	// Duration
	args = append(args, "-V", fmt.Sprintf("%d", duration))

	// Cursor
	if cursor {
		args = append(args, "-C")
	}

	// Region: -R x,y,w,h
	args = append(args, "-R", fmt.Sprintf("%.0f,%.0f,%.0f,%.0f",
		region.X, region.Y, region.Width, region.Height))

	args = append(args, outPath)
	return args
}

// Capture records a screen region to a .mov file using screencapture.
func Capture(ctx context.Context, region types.Rect, duration int, cursor bool, outPath string) error {
	args := BuildCaptureArgs(region, duration, cursor, outPath)
	cmd := exec.CommandContext(ctx, "screencapture", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("screencapture failed: %w\n%s", err, string(output))
	}
	return nil
}
