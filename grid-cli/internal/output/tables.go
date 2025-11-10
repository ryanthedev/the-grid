package output

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/olekukonko/tablewriter"
	"github.com/yourusername/grid-cli/internal/models"
)

// PrintWindowsTable prints windows in a table format
func PrintWindowsTable(windows []*models.Window) {
	table := tablewriter.NewWriter(os.Stdout)
	table.Header("ID", "Title", "App", "Space", "Size", "Minimized")

	// Sort by ID
	sort.Slice(windows, func(i, j int) bool {
		return windows[i].ID < windows[j].ID
	})

	for _, win := range windows {
		minimized := ""
		if win.IsMinimized {
			minimized = ""
		}

		spaces := formatIntSlice(win.Spaces)
		title := truncate(win.Title, 30)
		appName := truncate(win.AppName, 20)
		size := fmt.Sprintf("%.0fx%.0f", win.GetWidth(), win.GetHeight())

		table.Append(
			fmt.Sprintf("%d", win.ID),
			title,
			appName,
			spaces,
			size,
			minimized,
		)
	}

	table.Render()
}

// PrintSpacesTable prints spaces in a table format
func PrintSpacesTable(spaces []*models.Space) {
	table := tablewriter.NewWriter(os.Stdout)
	table.Header("ID", "UUID", "Type", "Display", "Active", "Windows")

	for _, space := range spaces {
		active := ""
		if space.IsActive {
			active = ""
		}

		uuid := truncate(space.UUID, 12)
		displayUUID := truncate(space.DisplayUUID, 12)

		table.Append(
			space.GetIDString(),
			uuid,
			space.Type,
			displayUUID,
			active,
			fmt.Sprintf("%d", space.GetWindowCount()),
		)
	}

	table.Render()
}

// PrintDisplaysTable prints displays in a table format
func PrintDisplaysTable(displays []*models.Display) {
	table := tablewriter.NewWriter(os.Stdout)
	table.Header("Name", "ID", "Resolution", "Scale", "Type", "Refresh", "Spaces")

	for _, display := range displays {
		name := truncate(display.GetDisplayName(), 25)
		displayID := display.GetDisplayIDString()
		resolution := display.GetResolutionString()
		scale := display.GetScaleString()

		// Combine indicators for type
		var indicators []string
		if display.IsMainDisplay() {
			indicators = append(indicators, "★")
		}
		if display.IsBuiltinDisplay() {
			indicators = append(indicators, "💻")
		}
		typeIndicator := strings.Join(indicators, " ")

		refresh := display.GetRefreshRateString()
		spaces := strings.Join(display.GetSpaceIDs(), ", ")

		table.Append(
			name,
			displayID,
			resolution,
			scale,
			typeIndicator,
			refresh,
			spaces,
		)
	}

	table.Render()
}

// PrintApplicationsTable prints applications in a table format
func PrintApplicationsTable(apps []*models.Application) {
	table := tablewriter.NewWriter(os.Stdout)
	table.Header("PID", "Name", "Bundle ID", "Active", "Hidden", "Windows")

	// Sort by name
	sort.Slice(apps, func(i, j int) bool {
		return apps[i].LocalizedName < apps[j].LocalizedName
	})

	for _, app := range apps {
		active := ""
		if app.IsActive {
			active = ""
		}
		hidden := ""
		if app.IsHidden {
			hidden = ""
		}

		name := truncate(app.LocalizedName, 25)
		bundleID := truncate(app.BundleIdentifier, 35)

		table.Append(
			fmt.Sprintf("%d", app.PID),
			name,
			bundleID,
			active,
			hidden,
			fmt.Sprintf("%d", app.GetWindowCount()),
		)
	}

	table.Render()
}

// PrintWindowDetail prints detailed information about a single window
func PrintWindowDetail(win *models.Window, app *models.Application) {
	fmt.Printf("Window ID: %d\n", win.ID)
	fmt.Printf("Title: %s\n", win.Title)
	fmt.Printf("Application: %s (PID: %d)\n", win.AppName, win.PID)
	if app != nil {
		fmt.Printf("Bundle ID: %s\n", app.BundleIdentifier)
	}
	fmt.Printf("Position: (%.0f, %.0f)\n", win.GetX(), win.GetY())
	fmt.Printf("Size: %.0fx%.0f\n", win.GetWidth(), win.GetHeight())
	fmt.Printf("Frame: %s\n", win.FormatFrame())
	fmt.Printf("Spaces: %v\n", win.Spaces)
	fmt.Printf("Minimized: %v\n", win.IsMinimized)
	fmt.Printf("Ordered In: %v\n", win.IsOrderedIn)
	fmt.Printf("Alpha: %v\n", win.Alpha)
	fmt.Printf("Has Transform: %v\n", win.HasTransform)
}

// Helper functions

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}

func formatIntSlice(ints []interface{}) string {
	if len(ints) == 0 {
		return "-"
	}
	strs := make([]string, 0, len(ints))
	for _, v := range ints {
		switch val := v.(type) {
		case int:
			strs = append(strs, fmt.Sprintf("%d", val))
		case float64:
			strs = append(strs, fmt.Sprintf("%.0f", val))
		case bool:
			strs = append(strs, "large")
		default:
			strs = append(strs, fmt.Sprintf("%v", val))
		}
	}
	return strings.Join(strs, ", ")
}
