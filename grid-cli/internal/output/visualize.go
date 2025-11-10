package output

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/fatih/color"
	"github.com/yourusername/grid-cli/internal/models"
	"golang.org/x/sys/unix"
)

// VisualizationOptions controls the appearance of the visualization
type VisualizationOptions struct {
	UseUnicode bool
	ShowIDs    bool
	MaxWidth   int
	MaxHeight  int
}

// DefaultVisualizationOptions returns sensible defaults
func DefaultVisualizationOptions() VisualizationOptions {
	width, height := getTerminalSize()
	return VisualizationOptions{
		UseUnicode: supportsUnicode(),
		ShowIDs:    true,
		MaxWidth:   width,
		MaxHeight:  height,
	}
}

// VisualizeDisplay renders a spatial layout of windows for a specific display
func VisualizeDisplay(state *models.State, displayIndex int, opts VisualizationOptions) (string, error) {
	if displayIndex < 0 || displayIndex >= len(state.Displays) {
		return "", fmt.Errorf("display index %d out of range (have %d displays)", displayIndex, len(state.Displays))
	}

	display := state.Displays[displayIndex]

	// Get windows for this display by checking which space they're on
	windows := getWindowsForDisplay(state, display)

	if len(windows) == 0 {
		return fmt.Sprintf("Display %d: %s (no windows)\n", displayIndex, truncate(display.UUID, 12)), nil
	}

	// Create visualization
	result := visualizeWindowsForDisplay(windows, display, opts)

	// Add header
	displayName := display.GetDisplayName()
	resolution := display.GetResolutionString()
	header := fmt.Sprintf("Display %d: %s [%s] (Space %s active)\n",
		displayIndex,
		displayName,
		resolution,
		display.GetCurrentSpaceIDString())

	footer := fmt.Sprintf("\nTotal: %d windows\n", len(windows))

	return header + result + footer, nil
}

// VisualizeAllDisplays renders all displays side by side (or vertically if terminal is narrow)
func VisualizeAllDisplays(state *models.State, opts VisualizationOptions) (string, error) {
	if len(state.Displays) == 0 {
		return "No displays found\n", nil
	}

	// If terminal is narrow or only one display, show them vertically
	if opts.MaxWidth < 100 || len(state.Displays) == 1 {
		var result strings.Builder
		for i := range state.Displays {
			vis, err := VisualizeDisplay(state, i, opts)
			if err != nil {
				return "", err
			}
			result.WriteString(vis)
			if i < len(state.Displays)-1 {
				result.WriteString("\n")
			}
		}
		return result.String(), nil
	}

	// Show displays side by side (limit to 2 for readability)
	displayCount := len(state.Displays)
	if displayCount > 2 {
		displayCount = 2
	}

	var result strings.Builder
	for i := 0; i < displayCount; i++ {
		vis, err := VisualizeDisplay(state, i, opts)
		if err != nil {
			return "", err
		}
		result.WriteString(vis)
		if i < displayCount-1 {
			result.WriteString("\n")
		}
	}

	if len(state.Displays) > 2 {
		result.WriteString(fmt.Sprintf("\n(Showing 2 of %d displays. Use 'grid show display <index>' to view others)\n", len(state.Displays)))
	}

	return result.String(), nil
}

// visualizeWindowsForDisplay creates the actual ASCII visualization using display dimensions
func visualizeWindowsForDisplay(windows []*models.Window, display *models.Display, opts VisualizationOptions) string {
	if len(windows) == 0 {
		return "(no windows)\n"
	}

	// Sort windows by level (z-order) - draw back to front
	sortedWindows := make([]*models.Window, len(windows))
	copy(sortedWindows, windows)
	sort.Slice(sortedWindows, func(i, j int) bool {
		// Try to use Level field for sorting
		levelI, okI := sortedWindows[i].Level.(float64)
		levelJ, okJ := sortedWindows[j].Level.(float64)
		if okI && okJ {
			return levelI < levelJ
		}
		// Fallback to ID
		return sortedWindows[i].ID < sortedWindows[j].ID
	})

	// Create scaling context using actual display dimensions
	sc := NewScalingContextFromDisplay(display, opts.MaxWidth, opts.MaxHeight)
	canvas := NewCanvas(opts.MaxWidth, opts.MaxHeight, opts.UseUnicode)

	return renderWindowsOnCanvas(sortedWindows, sc, canvas)
}

// visualizeWindows creates the actual ASCII visualization (legacy - infers from windows)
func visualizeWindows(windows []*models.Window, opts VisualizationOptions) string {
	if len(windows) == 0 {
		return "(no windows)\n"
	}

	// Sort windows by level (z-order) - draw back to front
	sortedWindows := make([]*models.Window, len(windows))
	copy(sortedWindows, windows)
	sort.Slice(sortedWindows, func(i, j int) bool {
		// Try to use Level field for sorting
		levelI, okI := sortedWindows[i].Level.(float64)
		levelJ, okJ := sortedWindows[j].Level.(float64)
		if okI && okJ {
			return levelI < levelJ
		}
		// Fallback to ID
		return sortedWindows[i].ID < sortedWindows[j].ID
	})

	// Create scaling context from windows
	sc := NewScalingContext(sortedWindows, opts.MaxWidth, opts.MaxHeight)
	canvas := NewCanvas(opts.MaxWidth, opts.MaxHeight, opts.UseUnicode)

	return renderWindowsOnCanvas(sortedWindows, sc, canvas)
}

// renderWindowsOnCanvas draws windows onto a canvas
func renderWindowsOnCanvas(sortedWindows []*models.Window, sc *ScalingContext, canvas *Canvas) string {
	// Draw display boundary
	canvas.DrawBox(0, 0, sc.TermWidth, sc.TermHeight)

	// Draw each window
	for _, win := range sortedWindows {
		if win.IsMinimized {
			continue
		}

		// Transform coordinates
		x, y := sc.PixelToTerminal(win.GetX(), win.GetY())
		w, h := sc.ScaleSize(win.GetWidth(), win.GetHeight())

		// Clamp to canvas bounds
		x, y, w, h = sc.ClampToCanvas(x, y, w, h)

		// Skip if too small
		if w < 3 || h < 2 {
			continue
		}

		// Draw window box
		canvas.DrawBox(x, y, w, h)

		// Create label (without showing IDs by default)
		label := createWindowLabel(win, false)

		// Draw label if it fits
		if len(label) <= w-2 && h >= 2 {
			canvas.DrawText(x+1, y+1, truncate(label, w-2))
		}
	}

	return canvas.String()
}

// getWindowsForDisplay returns all windows on the given display's spaces
func getWindowsForDisplay(state *models.State, display *models.Display) []*models.Window {
	// Get space IDs for this display
	spaceIDs := make(map[string]bool)
	for _, spaceID := range display.GetSpaceIDs() {
		spaceIDs[spaceID] = true
	}

	// Find windows on these spaces
	var windows []*models.Window
	for _, win := range state.Windows {
		// Check if window is on any of this display's spaces
		primarySpace := win.GetPrimarySpace()
		if spaceIDs[primarySpace] {
			windows = append(windows, win)
		}
	}

	return windows
}

// createWindowLabel creates a label for a window
func createWindowLabel(win *models.Window, showID bool) string {
	appName := win.AppName
	if appName == "" {
		appName = "Unknown"
	}

	size := fmt.Sprintf("%.0fx%.0f", win.GetWidth(), win.GetHeight())

	if showID {
		return fmt.Sprintf("[%d] %s (%s)", win.ID, appName, size)
	}
	return fmt.Sprintf("%s (%s)", appName, size)
}

// getTerminalSize returns the current terminal dimensions
func getTerminalSize() (width, height int) {
	ws, err := unix.IoctlGetWinsize(int(os.Stdout.Fd()), unix.TIOCGWINSZ)
	if err != nil {
		// Default to 80x24 if we can't detect
		return 80, 24
	}
	return int(ws.Col), int(ws.Row)
}

// supportsUnicode checks if the terminal supports Unicode
func supportsUnicode() bool {
	// Check LANG and LC_ALL environment variables
	lang := os.Getenv("LANG")
	lcAll := os.Getenv("LC_ALL")

	return strings.Contains(lang, "UTF-8") || strings.Contains(lcAll, "UTF-8")
}

// PrintVisualization prints a colored visualization to stdout
func PrintVisualization(state *models.State, displayIndex int, opts VisualizationOptions) error {
	var result string
	var err error

	if displayIndex < 0 {
		result, err = VisualizeAllDisplays(state, opts)
	} else {
		result, err = VisualizeDisplay(state, displayIndex, opts)
	}

	if err != nil {
		return err
	}

	// Apply color if enabled
	if color.NoColor {
		fmt.Print(result)
	} else {
		cyan := color.New(color.FgCyan)
		cyan.Print(result)
	}

	return nil
}
