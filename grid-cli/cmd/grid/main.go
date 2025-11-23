package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/yourusername/grid-cli/internal/client"
	"github.com/yourusername/grid-cli/internal/models"
	"github.com/yourusername/grid-cli/internal/output"
)

var (
	socketPath string
	timeout    time.Duration
	jsonOutput bool
	noColor    bool

	// Color functions
	successColor = color.New(color.FgGreen, color.Bold)
	errorColor   = color.New(color.FgRed, color.Bold)
	infoColor    = color.New(color.FgCyan)
	keyColor     = color.New(color.FgYellow)
)

// rootCmd is the base command
var rootCmd = &cobra.Command{
	Use:   "grid",
	Short: "GridServer CLI - macOS window manager client",
	Long: `Grid is a command-line client for GridServer, a powerful macOS window manager.

It allows you to query window state, manipulate window positions and sizes,
and move windows between spaces and displays.`,
	Version: "0.1.0",
}

// pingCmd tests server connectivity
var pingCmd = &cobra.Command{
	Use:   "ping",
	Short: "Test connection to GridServer",
	Long:  `Sends a ping request to the server to test connectivity and response time.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		start := time.Now()
		result, err := c.Ping(context.Background())
		elapsed := time.Since(start)

		if err != nil {
			printError(fmt.Sprintf("Ping failed: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Println("✓ Pong received")
		fmt.Printf("Response time: %v\n", elapsed)
		if ts, ok := result["timestamp"].(float64); ok {
			fmt.Printf("Server timestamp: %v\n", time.Unix(int64(ts), 0))
		}

		return nil
	},
}

// infoCmd gets server information
var infoCmd = &cobra.Command{
	Use:   "info",
	Short: "Get GridServer information",
	Long:  `Retrieves information about the GridServer including version and capabilities.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.GetServerInfo(context.Background())
		if err != nil {
			printError(fmt.Sprintf("Failed to get server info: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		// Pretty print server info
		if name, ok := result["name"].(string); ok {
			keyColor.Print("Server: ")
			fmt.Println(name)
		}
		if version, ok := result["version"].(string); ok {
			keyColor.Print("Version: ")
			fmt.Println(version)
		}
		if platform, ok := result["platform"].(string); ok {
			keyColor.Print("Platform: ")
			fmt.Println(platform)
		}

		if caps, ok := result["capabilities"].(map[string]interface{}); ok {
			keyColor.Println("\nCapabilities:")
			for k, v := range caps {
				if enabled, ok := v.(bool); ok && enabled {
					successColor.Printf("  ✓ %s\n", k)
				}
			}
		}

		return nil
	},
}

// dumpCmd dumps the complete state
var dumpCmd = &cobra.Command{
	Use:   "dump",
	Short: "Dump complete window manager state",
	Long:  `Retrieves and displays the complete window manager state including windows, spaces, displays, and applications.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.Dump(context.Background())
		if err != nil {
			printError(fmt.Sprintf("Failed to dump state: %v", err))
			return err
		}

		// Always output JSON for dump (it's too complex for human format)
		return printJSON(result)
	},
}

// showCmd is the parent command for visualization subcommands
var showCmd = &cobra.Command{
	Use:   "show",
	Short: "Visualize window layouts",
	Long:  `Displays ASCII/Unicode visualizations of window layouts on displays.`,
}

// Visualization flags
var (
	showASCII     bool
	showUnicode   bool
	showNoIDs     bool
	showWidth     int
	showHeight    int
)

// showLayoutCmd visualizes all displays
var showLayoutCmd = &cobra.Command{
	Use:   "layout",
	Short: "Show layout of all displays with windows",
	Long: `Displays a spatial ASCII/Unicode representation of all displays with their windows.
Windows are shown as boxes with their ID, application name, and size.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		state, err := getState()
		if err != nil {
			return err
		}

		opts := getVisualizationOptions()
		return output.PrintVisualization(state, -1, opts)
	},
}

// showDisplayCmd visualizes a specific display
var showDisplayCmd = &cobra.Command{
	Use:   "display <index>",
	Short: "Show layout of a specific display",
	Long: `Displays a spatial ASCII/Unicode representation of a specific display with its windows.
Windows are shown as boxes with their ID, application name, and size.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		displayIndex, err := strconv.Atoi(args[0])
		if err != nil {
			printError("Invalid display index")
			return fmt.Errorf("invalid display index: %v", err)
		}

		state, err := getState()
		if err != nil {
			return err
		}

		opts := getVisualizationOptions()
		return output.PrintVisualization(state, displayIndex, opts)
	},
}

// listCmd is the parent command for list subcommands
var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List windows, spaces, applications, or displays",
	Long:  `Lists various components of the window manager state in a table format.`,
}

// listWindowsCmd lists all windows
var listWindowsCmd = &cobra.Command{
	Use:   "windows",
	Short: "List all windows",
	Long:  `Lists all windows with their IDs, titles, applications, and positions.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		state, err := getState()
		if err != nil {
			return err
		}

		windows := state.GetWindows()
		if len(windows) == 0 {
			fmt.Println("No windows found")
			return nil
		}

		if jsonOutput {
			return printJSON(windows)
		}

		output.PrintWindowsTable(windows)
		fmt.Printf("\nTotal: %d windows\n", len(windows))
		return nil
	},
}

// listSpacesCmd lists all spaces
var listSpacesCmd = &cobra.Command{
	Use:   "spaces",
	Short: "List all spaces",
	Long:  `Lists all spaces with their IDs, types, and window counts.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		state, err := getState()
		if err != nil {
			return err
		}

		if len(state.Spaces) == 0 {
			fmt.Println("No spaces found")
			return nil
		}

		// Convert map to slice
		spaces := make([]*models.Space, 0, len(state.Spaces))
		for _, s := range state.Spaces {
			spaces = append(spaces, s)
		}

		if jsonOutput {
			return printJSON(spaces)
		}

		output.PrintSpacesTable(spaces)
		fmt.Printf("\nTotal: %d spaces\n", len(spaces))
		return nil
	},
}

// listDisplaysCmd lists all displays
var listDisplaysCmd = &cobra.Command{
	Use:   "displays",
	Short: "List all displays",
	Long:  `Lists all displays with their UUIDs and associated spaces.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		state, err := getState()
		if err != nil {
			return err
		}

		if len(state.Displays) == 0 {
			fmt.Println("No displays found")
			return nil
		}

		if jsonOutput {
			return printJSON(state.Displays)
		}

		output.PrintDisplaysTable(state.Displays)
		fmt.Printf("\nTotal: %d displays\n", len(state.Displays))
		return nil
	},
}

// listAppsCmd lists all applications
var listAppsCmd = &cobra.Command{
	Use:   "apps",
	Short: "List all applications",
	Long:  `Lists all applications with their PIDs, names, and window counts.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		state, err := getState()
		if err != nil {
			return err
		}

		apps := state.GetApplications()
		if len(apps) == 0 {
			fmt.Println("No applications found")
			return nil
		}

		if jsonOutput {
			return printJSON(apps)
		}

		output.PrintApplicationsTable(apps)
		fmt.Printf("\nTotal: %d applications\n", len(apps))
		return nil
	},
}

// windowCmd is the parent command for window subcommands
var windowCmd = &cobra.Command{
	Use:   "window",
	Short: "Interact with specific windows",
	Long:  `Commands for getting information about or manipulating specific windows.`,
}

// windowGetCmd gets details about a specific window
var windowGetCmd = &cobra.Command{
	Use:   "get <window-id>",
	Short: "Get details about a specific window",
	Long:  `Retrieves and displays detailed information about a window by its ID.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		state, err := getState()
		if err != nil {
			return err
		}

		window := state.FindWindowByID(windowID)
		if window == nil {
			return fmt.Errorf("window %d not found", windowID)
		}

		if jsonOutput {
			return printJSON(window)
		}

		app := state.FindApplicationByPID(window.PID)
		output.PrintWindowDetail(window, app)
		return nil
	},
}

// windowFindCmd finds windows by title pattern
var windowFindCmd = &cobra.Command{
	Use:   "find <pattern>",
	Short: "Find windows by title pattern",
	Long:  `Searches for windows whose title contains the given pattern (case-insensitive).`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		pattern := strings.ToLower(args[0])

		state, err := getState()
		if err != nil {
			return err
		}

		// Filter windows by title pattern
		var matches []*models.Window
		for _, win := range state.Windows {
			if strings.Contains(strings.ToLower(win.Title), pattern) ||
			   strings.Contains(strings.ToLower(win.AppName), pattern) {
				matches = append(matches, win)
			}
		}

		if len(matches) == 0 {
			fmt.Printf("No windows found matching '%s'\n", args[0])
			return nil
		}

		if jsonOutput {
			return printJSON(matches)
		}

		output.PrintWindowsTable(matches)
		fmt.Printf("\nFound %d windows matching '%s'\n", len(matches), args[0])
		return nil
	},
}

// Window manipulation command variables
var (
	moveX, moveY         float64
	resizeWidth, resizeHeight float64
	updateX, updateY, updateWidth, updateHeight float64
	toSpace              string
	toDisplay            string
	centerWindow         bool
)

// windowMoveCmd moves a window to a specific position
var windowMoveCmd = &cobra.Command{
	Use:   "move <window-id>",
	Short: "Move a window to a specific position",
	Long:  `Moves a window to the specified X and Y coordinates.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		updates := map[string]interface{}{
			"x": moveX,
			"y": moveY,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.UpdateWindow(context.Background(), windowID, updates)
		if err != nil {
			printError(fmt.Sprintf("Failed to move window: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %d moved to (%.0f, %.0f)\n", windowID, moveX, moveY)
		if updates, ok := result["updatesApplied"].([]interface{}); ok && len(updates) > 0 {
			fmt.Printf("  Applied: %v\n", updates)
		}
		return nil
	},
}

// windowResizeCmd resizes a window
var windowResizeCmd = &cobra.Command{
	Use:   "resize <window-id>",
	Short: "Resize a window",
	Long:  `Resizes a window to the specified width and height.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		updates := map[string]interface{}{
			"width":  resizeWidth,
			"height": resizeHeight,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.UpdateWindow(context.Background(), windowID, updates)
		if err != nil {
			printError(fmt.Sprintf("Failed to resize window: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %d resized to %.0fx%.0f\n", windowID, resizeWidth, resizeHeight)
		if updates, ok := result["updatesApplied"].([]interface{}); ok && len(updates) > 0 {
			fmt.Printf("  Applied: %v\n", updates)
		}
		return nil
	},
}

// windowUpdateCmd updates multiple window properties at once
var windowUpdateCmd = &cobra.Command{
	Use:   "update <window-id>",
	Short: "Update window position and/or size",
	Long:  `Updates a window's position and/or size. Specify any combination of --x, --y, --width, --height.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		updates := make(map[string]interface{})

		if cmd.Flags().Changed("x") {
			updates["x"] = updateX
		}
		if cmd.Flags().Changed("y") {
			updates["y"] = updateY
		}
		if cmd.Flags().Changed("width") {
			updates["width"] = updateWidth
		}
		if cmd.Flags().Changed("height") {
			updates["height"] = updateHeight
		}

		if len(updates) == 0 {
			return fmt.Errorf("no updates specified (use --x, --y, --width, or --height)")
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.UpdateWindow(context.Background(), windowID, updates)
		if err != nil {
			printError(fmt.Sprintf("Failed to update window: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %d updated\n", windowID)
		if applied, ok := result["updatesApplied"].([]interface{}); ok && len(applied) > 0 {
			fmt.Printf("  Applied: %v\n", applied)
		}
		return nil
	},
}

// windowToSpaceCmd moves a window to a specific space
var windowToSpaceCmd = &cobra.Command{
	Use:   "to-space <window-id> <space-id>",
	Short: "Move a window to a specific space",
	Long:  `Moves a window to the specified space ID.`,
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		spaceID := args[1]

		updates := map[string]interface{}{
			"spaceId": spaceID,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.UpdateWindow(context.Background(), windowID, updates)
		if err != nil {
			printError(fmt.Sprintf("Failed to move window to space: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %d moved to space %s\n", windowID, spaceID)
		if updates, ok := result["updatesApplied"].([]interface{}); ok && len(updates) > 0 {
			fmt.Printf("  Applied: %v\n", updates)
		}
		return nil
	},
}

// windowToDisplayCmd moves a window to a specific display
var windowToDisplayCmd = &cobra.Command{
	Use:   "to-display <window-id> <display-uuid>",
	Short: "Move a window to a specific display",
	Long:  `Moves a window to the specified display UUID.`,
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		displayUUID := args[1]

		updates := map[string]interface{}{
			"displayUuid": displayUUID,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.UpdateWindow(context.Background(), windowID, updates)
		if err != nil {
			printError(fmt.Sprintf("Failed to move window to display: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %d moved to display %s\n", windowID, displayUUID)
		if updates, ok := result["updatesApplied"].([]interface{}); ok && len(updates) > 0 {
			fmt.Printf("  Applied: %v\n", updates)
		}
		return nil
	},
}

// windowCenterCmd centers a window on its current display
var windowCenterCmd = &cobra.Command{
	Use:   "center <window-id>",
	Short: "Center a window on its display",
	Long:  `Centers a window on its current display. Calculates the center position based on display size.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		// Get current state to calculate center position
		state, err := getState()
		if err != nil {
			return err
		}

		window := state.FindWindowByID(windowID)
		if window == nil {
			return fmt.Errorf("window %d not found", windowID)
		}

		// Find the display containing this window's primary space
		if len(state.Displays) == 0 {
			return fmt.Errorf("no displays found")
		}

		// Find the display for this window based on its primary space
		var targetDisplay *models.Display
		primarySpace := window.GetPrimarySpace()
		for _, display := range state.Displays {
			for _, spaceID := range display.GetSpaceIDs() {
				if spaceID == primarySpace {
					targetDisplay = display
					break
				}
			}
			if targetDisplay != nil {
				break
			}
		}

		// Fall back to first display if we can't find the window's display
		if targetDisplay == nil {
			targetDisplay = state.Displays[0]
		}

		// Use actual display dimensions
		displayWidth := 1920.0  // Default fallback
		displayHeight := 1080.0 // Default fallback
		if targetDisplay.PixelWidth != nil && targetDisplay.PixelHeight != nil {
			displayWidth = float64(*targetDisplay.PixelWidth)
			displayHeight = float64(*targetDisplay.PixelHeight)
		}

		winWidth := window.GetWidth()
		winHeight := window.GetHeight()

		centerX := (displayWidth - winWidth) / 2
		centerY := (displayHeight - winHeight) / 2

		updates := map[string]interface{}{
			"x": centerX,
			"y": centerY,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.UpdateWindow(context.Background(), windowID, updates)
		if err != nil {
			printError(fmt.Sprintf("Failed to center window: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %d centered at (%.0f, %.0f)\n", windowID, centerX, centerY)
		if updates, ok := result["updatesApplied"].([]interface{}); ok && len(updates) > 0 {
			fmt.Printf("  Applied: %v\n", updates)
		}
		return nil
	},
}

// MARK: - MSS Window Commands (Opacity, Layer, Sticky, Minimize)

var opacityValue float64
var opacityDuration float64
var layerValue string
var stickyValue bool

// windowSetOpacityCmd sets window opacity
var windowSetOpacityCmd = &cobra.Command{
	Use:   "set-opacity <window-id> <opacity>",
	Short: "Set window opacity (requires MSS)",
	Long:  `Sets the opacity of a window instantly. Opacity range: 0.0 (transparent) to 1.0 (opaque). Requires MSS to be installed and loaded.`,
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		opacity, err := strconv.ParseFloat(args[1], 32)
		if err != nil || opacity < 0 || opacity > 1 {
			return fmt.Errorf("invalid opacity value: must be between 0.0 and 1.0")
		}

		params := map[string]interface{}{
			"windowId": args[0],
			"opacity":  float32(opacity),
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.setOpacity", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to set window opacity: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %s opacity set to %.2f\n", args[0], opacity)
		return nil
	},
}

// windowFadeOpacityCmd fades window opacity over time
var windowFadeOpacityCmd = &cobra.Command{
	Use:   "fade-opacity <window-id> <opacity> <duration>",
	Short: "Fade window opacity over time (requires MSS)",
	Long:  `Fades window opacity to target value over the specified duration in seconds. Requires MSS.`,
	Args:  cobra.ExactArgs(3),
	RunE: func(cmd *cobra.Command, args []string) error {
		opacity, err := strconv.ParseFloat(args[1], 32)
		if err != nil || opacity < 0 || opacity > 1 {
			return fmt.Errorf("invalid opacity value: must be between 0.0 and 1.0")
		}

		duration, err := strconv.ParseFloat(args[2], 32)
		if err != nil || duration <= 0 {
			return fmt.Errorf("invalid duration: must be positive number in seconds")
		}

		params := map[string]interface{}{
			"windowId": args[0],
			"opacity":  float32(opacity),
			"duration": float32(duration),
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.fadeOpacity", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to fade window opacity: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %s fading to opacity %.2f over %.2f seconds\n", args[0], opacity, duration)
		return nil
	},
}

// windowGetOpacityCmd gets window opacity
var windowGetOpacityCmd = &cobra.Command{
	Use:   "get-opacity <window-id>",
	Short: "Get window opacity (requires MSS)",
	Long:  `Retrieves the current opacity value of a window. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.getOpacity", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to get window opacity: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		if opacity, ok := result["opacity"].(float64); ok {
			fmt.Printf("Window %s opacity: %.2f\n", args[0], opacity)
		}
		return nil
	},
}

// windowSetLayerCmd sets window layer (above/normal/below)
var windowSetLayerCmd = &cobra.Command{
	Use:   "set-layer <window-id> <layer>",
	Short: "Set window layer: above, normal, or below (requires MSS)",
	Long:  `Sets the window stacking layer. Values: 'above' (always on top), 'normal' (default), 'below' (always behind). Requires MSS.`,
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		layer := strings.ToLower(args[1])
		if layer != "above" && layer != "normal" && layer != "below" {
			return fmt.Errorf("invalid layer: must be 'above', 'normal', or 'below'")
		}

		params := map[string]interface{}{
			"windowId": args[0],
			"layer":    layer,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.setLayer", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to set window layer: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %s layer set to '%s'\n", args[0], layer)
		return nil
	},
}

// windowGetLayerCmd gets window layer
var windowGetLayerCmd = &cobra.Command{
	Use:   "get-layer <window-id>",
	Short: "Get window layer (requires MSS)",
	Long:  `Retrieves the current stacking layer of a window. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.getLayer", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to get window layer: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		if layer, ok := result["layer"].(string); ok {
			fmt.Printf("Window %s layer: %s\n", args[0], layer)
		}
		return nil
	},
}

// windowSetStickyCmd makes window visible on all spaces
var windowSetStickyCmd = &cobra.Command{
	Use:   "set-sticky <window-id> <true|false>",
	Short: "Make window visible on all spaces (requires MSS)",
	Long:  `Sets whether a window is sticky (visible on all spaces). Requires MSS.`,
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		sticky, err := strconv.ParseBool(args[1])
		if err != nil {
			return fmt.Errorf("invalid sticky value: must be 'true' or 'false'")
		}

		params := map[string]interface{}{
			"windowId": args[0],
			"sticky":   sticky,
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.setSticky", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to set window sticky: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		if sticky {
			successColor.Printf("✓ Window %s is now visible on all spaces\n", args[0])
		} else {
			successColor.Printf("✓ Window %s is now visible only on its assigned spaces\n", args[0])
		}
		return nil
	},
}

// windowIsStickyCmd checks if window is sticky
var windowIsStickyCmd = &cobra.Command{
	Use:   "is-sticky <window-id>",
	Short: "Check if window is sticky (requires MSS)",
	Long:  `Checks whether a window is sticky (visible on all spaces). Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.isSticky", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to check window sticky status: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		if sticky, ok := result["sticky"].(bool); ok {
			if sticky {
				fmt.Printf("Window %s is sticky (visible on all spaces)\n", args[0])
			} else {
				fmt.Printf("Window %s is not sticky\n", args[0])
			}
		}
		return nil
	},
}

// windowMinimizeCmd minimizes a window
var windowMinimizeCmd = &cobra.Command{
	Use:   "minimize <window-id>",
	Short: "Minimize a window (requires MSS)",
	Long:  `Minimizes a window to the Dock. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.minimize", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to minimize window: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %s minimized\n", args[0])
		return nil
	},
}

// windowUnminimizeCmd restores a minimized window
var windowUnminimizeCmd = &cobra.Command{
	Use:   "unminimize <window-id>",
	Short: "Restore a minimized window (requires MSS)",
	Long:  `Restores a minimized window from the Dock. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.unminimize", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to unminimize window: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Window %s restored\n", args[0])
		return nil
	},
}

// windowIsMinimizedCmd checks if window is minimized
var windowIsMinimizedCmd = &cobra.Command{
	Use:   "is-minimized <window-id>",
	Short: "Check if window is minimized (requires MSS)",
	Long:  `Checks whether a window is currently minimized. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "window.isMinimized", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to check window minimized status: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		if minimized, ok := result["minimized"].(bool); ok {
			if minimized {
				fmt.Printf("Window %s is minimized\n", args[0])
			} else {
				fmt.Printf("Window %s is not minimized\n", args[0])
			}
		}
		return nil
	},
}

// MARK: - Space Management Commands (MSS)

// spaceCmd is the parent command for space subcommands
var spaceCmd = &cobra.Command{
	Use:   "space",
	Short: "Manage spaces (requires MSS)",
	Long:  `Commands for creating, destroying, and focusing spaces. Requires MSS.`,
}

// spaceCreateCmd creates a new space
var spaceCreateCmd = &cobra.Command{
	Use:   "create <display-space-id>",
	Short: "Create a new space on a display (requires MSS)",
	Long:  `Creates a new space on the same display as the specified space ID. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"displaySpaceId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "space.create", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to create space: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Space created on display containing space %s\n", args[0])
		return nil
	},
}

// spaceDestroyCmd destroys a space
var spaceDestroyCmd = &cobra.Command{
	Use:   "destroy <space-id>",
	Short: "Destroy a space (requires MSS)",
	Long:  `Destroys (deletes) a space. Windows on this space will be moved to other spaces. Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"spaceId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "space.destroy", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to destroy space: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Space %s destroyed\n", args[0])
		return nil
	},
}

// spaceFocusCmd focuses (switches to) a space
var spaceFocusCmd = &cobra.Command{
	Use:   "focus <space-id>",
	Short: "Switch to a space (requires MSS)",
	Long:  `Switches to the specified space (makes it active). Requires MSS.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		params := map[string]interface{}{
			"spaceId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(context.Background(), "space.focus", params)
		if err != nil {
			printError(fmt.Sprintf("Failed to focus space: %v", err))
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Switched to space %s\n", args[0])
		return nil
	},
}

func init() {
	// Global flags
	rootCmd.PersistentFlags().StringVar(&socketPath, "socket", client.DefaultSocketPath, "Unix socket path")
	rootCmd.PersistentFlags().DurationVar(&timeout, "timeout", client.DefaultTimeout, "Request timeout")
	rootCmd.PersistentFlags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	rootCmd.PersistentFlags().BoolVar(&noColor, "no-color", false, "Disable colored output")

	// Add top-level commands
	rootCmd.AddCommand(pingCmd)
	rootCmd.AddCommand(infoCmd)
	rootCmd.AddCommand(dumpCmd)
	rootCmd.AddCommand(showCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(windowCmd)
	rootCmd.AddCommand(spaceCmd)

	// Add show subcommands
	showCmd.AddCommand(showLayoutCmd)
	showCmd.AddCommand(showDisplayCmd)

	// Add show flags
	showCmd.PersistentFlags().BoolVar(&showASCII, "ascii", false, "Force ASCII mode (no Unicode)")
	showCmd.PersistentFlags().BoolVar(&showUnicode, "unicode", false, "Force Unicode mode")
	showCmd.PersistentFlags().BoolVar(&showNoIDs, "no-ids", false, "Hide window IDs")
	showCmd.PersistentFlags().IntVar(&showWidth, "width", 0, "Override terminal width")
	showCmd.PersistentFlags().IntVar(&showHeight, "height", 0, "Override terminal height")

	// Add list subcommands
	listCmd.AddCommand(listWindowsCmd)
	listCmd.AddCommand(listSpacesCmd)
	listCmd.AddCommand(listDisplaysCmd)
	listCmd.AddCommand(listAppsCmd)

	// Add window subcommands
	windowCmd.AddCommand(windowGetCmd)
	windowCmd.AddCommand(windowFindCmd)
	windowCmd.AddCommand(windowMoveCmd)
	windowCmd.AddCommand(windowResizeCmd)
	windowCmd.AddCommand(windowUpdateCmd)
	windowCmd.AddCommand(windowToSpaceCmd)
	windowCmd.AddCommand(windowToDisplayCmd)
	windowCmd.AddCommand(windowCenterCmd)
	windowCmd.AddCommand(windowSetOpacityCmd)
	windowCmd.AddCommand(windowFadeOpacityCmd)
	windowCmd.AddCommand(windowGetOpacityCmd)
	windowCmd.AddCommand(windowSetLayerCmd)
	windowCmd.AddCommand(windowGetLayerCmd)
	windowCmd.AddCommand(windowSetStickyCmd)
	windowCmd.AddCommand(windowIsStickyCmd)
	windowCmd.AddCommand(windowMinimizeCmd)
	windowCmd.AddCommand(windowUnminimizeCmd)
	windowCmd.AddCommand(windowIsMinimizedCmd)

	// Add space subcommands
	spaceCmd.AddCommand(spaceCreateCmd)
	spaceCmd.AddCommand(spaceDestroyCmd)
	spaceCmd.AddCommand(spaceFocusCmd)

	// Add flags for manipulation commands
	windowMoveCmd.Flags().Float64Var(&moveX, "x", 0, "X position")
	windowMoveCmd.Flags().Float64Var(&moveY, "y", 0, "Y position")
	windowMoveCmd.MarkFlagRequired("x")
	windowMoveCmd.MarkFlagRequired("y")

	windowResizeCmd.Flags().Float64Var(&resizeWidth, "width", 0, "Width in pixels")
	windowResizeCmd.Flags().Float64Var(&resizeHeight, "height", 0, "Height in pixels")
	windowResizeCmd.MarkFlagRequired("width")
	windowResizeCmd.MarkFlagRequired("height")

	windowUpdateCmd.Flags().Float64Var(&updateX, "x", 0, "X position (optional)")
	windowUpdateCmd.Flags().Float64Var(&updateY, "y", 0, "Y position (optional)")
	windowUpdateCmd.Flags().Float64Var(&updateWidth, "width", 0, "Width in pixels (optional)")
	windowUpdateCmd.Flags().Float64Var(&updateHeight, "height", 0, "Height in pixels (optional)")

	// Disable color if requested
	cobra.OnInitialize(func() {
		if noColor {
			color.NoColor = true
		}
	})
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

// Helper functions

func printJSON(data interface{}) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(data)
}

func printError(msg string) {
	if noColor {
		fmt.Fprintln(os.Stderr, "Error:", msg)
	} else {
		errorColor.Fprint(os.Stderr, "✗ Error: ")
		fmt.Fprintln(os.Stderr, msg)
	}
}

// getState retrieves and parses the current state from the server
func getState() (*models.State, error) {
	c := client.NewClient(socketPath, timeout)
	defer c.Close()

	result, err := c.Dump(context.Background())
	if err != nil {
		printError(fmt.Sprintf("Failed to get state: %v", err))
		return nil, err
	}

	state, err := models.ParseState(result)
	if err != nil {
		printError(fmt.Sprintf("Failed to parse state: %v", err))
		return nil, err
	}

	return state, nil
}

// getVisualizationOptions builds options from flags
func getVisualizationOptions() output.VisualizationOptions {
	opts := output.DefaultVisualizationOptions()

	// Override with flags if set
	if showASCII {
		opts.UseUnicode = false
	}
	if showUnicode {
		opts.UseUnicode = true
	}
	if showNoIDs {
		opts.ShowIDs = false
	}
	if showWidth > 0 {
		opts.MaxWidth = showWidth
	}
	if showHeight > 0 {
		opts.MaxHeight = showHeight
	}

	return opts
}
