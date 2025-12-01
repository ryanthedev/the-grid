package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/yourusername/grid-cli/internal/client"
	gridCell "github.com/yourusername/grid-cli/internal/cell"
	gridConfig "github.com/yourusername/grid-cli/internal/config"
	gridFocus "github.com/yourusername/grid-cli/internal/focus"
	gridLayout "github.com/yourusername/grid-cli/internal/layout"
	"github.com/yourusername/grid-cli/internal/logging"
	"github.com/yourusername/grid-cli/internal/models"
	"github.com/yourusername/grid-cli/internal/output"
	gridReconcile "github.com/yourusername/grid-cli/internal/reconcile"
	gridServer "github.com/yourusername/grid-cli/internal/server"
	gridState "github.com/yourusername/grid-cli/internal/state"
	gridTypes "github.com/yourusername/grid-cli/internal/types"
	gridWindow "github.com/yourusername/grid-cli/internal/window"
)

var (
	socketPath string
	timeout    time.Duration
	jsonOutput bool
	noColor    bool
	debugMode  bool

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
	Long: `Lists all windows with their IDs, titles, applications, and positions.

By default, filters out system UI, utility windows, and borders (yabai-style filtering).
Use --all to show all windows including system components.`,
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

		// Apply filtering unless --all is specified
		showAll, _ := cmd.Flags().GetBool("all")
		if !showAll {
			windows = filterWindows(windows)
		}

		if len(windows) == 0 {
			fmt.Println("No windows found (try --all to show system windows)")
			return nil
		}

		if jsonOutput {
			return printJSON(windows)
		}

		output.PrintWindowsTable(windows)
		fmt.Printf("\nTotal: %d windows", len(windows))
		if !showAll {
			fmt.Printf(" (filtered, use --all to show all windows)")
		}
		fmt.Println()
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
			title := ""
			if win.Title != nil {
				title = *win.Title
			}
			appName := ""
			if win.AppName != nil {
				appName = *win.AppName
			}
			if strings.Contains(strings.ToLower(title), pattern) ||
			   strings.Contains(strings.ToLower(appName), pattern) {
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
	updateX, updateY, updateWidth, updateHeight float64
	toSpace                                     string
	toDisplay                                   string
)

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

// MARK: - Layout Commands

// layoutCmd is the parent command for layout subcommands
var gridLayoutCmd = &cobra.Command{
	Use:   "layout",
	Short: "Manage window layouts",
	Long:  `Commands for listing, applying, and cycling window layouts.`,
}

// layoutListCmd lists available layouts
var layoutListCmd = &cobra.Command{
	Use:   "list",
	Short: "List available layouts",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		if jsonOutput {
			return printJSON(cfg.Layouts)
		}

		fmt.Println("Available Layouts:")
		fmt.Println()
		for _, l := range cfg.Layouts {
			keyColor.Printf("  %s\n", l.ID)
			if l.Name != "" {
				fmt.Printf("    Name: %s\n", l.Name)
			}
			if l.Description != "" {
				fmt.Printf("    Description: %s\n", l.Description)
			}
			fmt.Printf("    Grid: %dx%d\n", len(l.Grid.Columns), len(l.Grid.Rows))
			fmt.Printf("    Cells: %d\n", len(l.Cells))
			fmt.Println()
		}

		return nil
	},
}

// layoutShowCmd shows layout details
var layoutShowCmd = &cobra.Command{
	Use:   "show <layout-id>",
	Short: "Show layout details",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		layoutID := args[0]

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		l, err := cfg.GetLayout(layoutID)
		if err != nil {
			return err
		}

		if jsonOutput {
			return printJSON(l)
		}

		keyColor.Printf("Layout: %s\n", l.ID)
		if l.Name != "" {
			fmt.Printf("Name: %s\n", l.Name)
		}
		if l.Description != "" {
			fmt.Printf("Description: %s\n", l.Description)
		}
		fmt.Println()

		fmt.Println("Grid:")
		fmt.Printf("  Columns: %s\n", formatTrackSizes(l.Columns))
		fmt.Printf("  Rows: %s\n", formatTrackSizes(l.Rows))
		fmt.Println()

		fmt.Println("Cells:")
		for _, cell := range l.Cells {
			fmt.Printf("  %s: col %d-%d, row %d-%d\n",
				cell.ID, cell.ColumnStart, cell.ColumnEnd, cell.RowStart, cell.RowEnd)
		}

		return nil
	},
}

// layoutApplyCmd applies a layout
var layoutApplyCmd = &cobra.Command{
	Use:   "apply <layout-id>",
	Short: "Apply a layout to the current space",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		layoutID := args[0]

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Apply layout using snapshot
		opts := gridLayout.DefaultApplyOptions()
		opts.BaseSpacing = cfg.GetBaseSpacing()
		if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
			opts.SettingsPadding = settingsPadding
		}
		if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
			opts.SettingsWindowSpacing = settingsWindowSpacing
		}

		if err := gridLayout.ApplyLayout(ctx, c, snap, cfg, runtimeState, layoutID, opts); err != nil {
			return fmt.Errorf("failed to apply layout: %w", err)
		}

		successColor.Printf("✓ Applied layout: %s\n", layoutID)
		return nil
	},
}

// layoutCycleCmd cycles to the next layout
var layoutCycleCmd = &cobra.Command{
	Use:   "cycle",
	Short: "Cycle to the next layout",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Cycle layout
		opts := gridLayout.DefaultApplyOptions()
		opts.BaseSpacing = cfg.GetBaseSpacing()
		if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
			opts.SettingsPadding = settingsPadding
		}
		if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
			opts.SettingsWindowSpacing = settingsWindowSpacing
		}

		newLayout, err := gridLayout.CycleLayout(ctx, c, snap, cfg, runtimeState, opts)
		if err != nil {
			return fmt.Errorf("failed to cycle layout: %w", err)
		}

		successColor.Printf("✓ Cycled to layout: %s\n", newLayout)
		return nil
	},
}

// layoutCurrentCmd shows the current layout
var layoutCurrentCmd = &cobra.Command{
	Use:   "current",
	Short: "Show current layout for space",
	RunE: func(cmd *cobra.Command, args []string) error {
		spaceID, _ := cmd.Flags().GetString("space")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		// If no space specified, get current from server using proper snapshot
		if spaceID == "" {
			c := client.NewClient(socketPath, timeout)
			defer c.Close()
			snap, err := gridServer.Fetch(context.Background(), c)
			if err != nil {
				return fmt.Errorf("failed to get current space: %w", err)
			}
			spaceID = snap.SpaceID
		}

		layoutID := runtimeState.GetCurrentLayoutForSpace(spaceID)
		if layoutID == "" {
			fmt.Println("No layout currently applied")
			return nil
		}

		if jsonOutput {
			return printJSON(map[string]string{
				"spaceId":  spaceID,
				"layoutId": layoutID,
			})
		}

		fmt.Printf("Current layout for space %s: %s\n", spaceID, layoutID)
		return nil
	},
}

// layoutReapplyCmd reapplies the current layout
var layoutReapplyCmd = &cobra.Command{
	Use:   "reapply",
	Short: "Reapply the current layout",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Reapply layout
		opts := gridLayout.DefaultApplyOptions()
		opts.BaseSpacing = cfg.GetBaseSpacing()
		if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
			opts.SettingsPadding = settingsPadding
		}
		if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
			opts.SettingsWindowSpacing = settingsWindowSpacing
		}

		if err := gridLayout.ReapplyLayout(ctx, c, snap, cfg, runtimeState, opts); err != nil {
			return fmt.Errorf("failed to reapply layout: %w", err)
		}

		successColor.Println("✓ Layout reapplied")
		return nil
	},
}

// MARK: - Config Commands

// gridConfigCmd is the parent command for config subcommands
var gridConfigCmd = &cobra.Command{
	Use:   "config",
	Short: "Manage configuration",
	Long:  `Commands for showing and validating grid configuration.`,
}

// configShowCmd shows current config
var configShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show current configuration",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		return printJSON(cfg)
	},
}

// configValidateCmd validates config file
var configValidateCmd = &cobra.Command{
	Use:   "validate [path]",
	Short: "Validate configuration file",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path := ""
		if len(args) > 0 {
			path = args[0]
		}

		cfg, err := gridConfig.LoadConfig(path)
		if err != nil {
			return fmt.Errorf("validation failed: %w", err)
		}

		if err := cfg.Validate(); err != nil {
			return fmt.Errorf("validation failed: %w", err)
		}

		successColor.Println("✓ Configuration is valid")
		fmt.Printf("  Layouts: %d\n", len(cfg.Layouts))
		fmt.Printf("  Spaces: %d\n", len(cfg.Spaces))
		fmt.Printf("  App Rules: %d\n", len(cfg.AppRules))

		return nil
	},
}

// configInitCmd creates default config
var configInitCmd = &cobra.Command{
	Use:   "init",
	Short: "Create default configuration file",
	RunE: func(cmd *cobra.Command, args []string) error {
		path := gridConfig.GetConfigPath()

		// Check if file exists
		if _, err := os.Stat(path); err == nil {
			return fmt.Errorf("config file already exists at %s", path)
		}

		defaultConfig := `# Grid Layout Configuration
settings:
  defaultStackMode: vertical
  cellPadding: 8
  animationDuration: 0.2
  focusFollowsMouse: false

layouts:
  - id: two-column
    name: Two Column
    description: Equal two-column split
    grid:
      columns: ["1fr", "1fr"]
      rows: ["1fr"]
    cells:
      - id: left
        column: "1/2"
        row: "1/2"
      - id: right
        column: "2/3"
        row: "1/2"

  - id: main-side
    name: Main + Sidebar
    description: Large main area with sidebar
    grid:
      columns: ["2fr", "1fr"]
      rows: ["1fr"]
    cells:
      - id: main
        column: "1/2"
        row: "1/2"
      - id: side
        column: "2/3"
        row: "1/2"

spaces:
  "1":
    name: Main
    layouts: [two-column, main-side]
    defaultLayout: two-column
    autoApply: false

appRules:
  - app: Finder
    float: true
`

		// Create directory
		dir := filepath.Dir(path)
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("failed to create config directory: %w", err)
		}

		// Write file
		if err := os.WriteFile(path, []byte(defaultConfig), 0644); err != nil {
			return fmt.Errorf("failed to write config file: %w", err)
		}

		successColor.Printf("✓ Created default config at: %s\n", path)
		return nil
	},
}

// MARK: - State Commands

// gridStateCmd is the parent command for state subcommands
var gridStateCmd = &cobra.Command{
	Use:   "state",
	Short: "Manage runtime state",
	Long:  `Commands for showing and resetting grid runtime state.`,
}

// stateShowCmd shows runtime state
var stateShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show runtime state",
	RunE: func(cmd *cobra.Command, args []string) error {
		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		if jsonOutput {
			return printJSON(runtimeState)
		}

		summary := runtimeState.Summary()
		keyColor.Print("State Version: ")
		fmt.Printf("%v\n", summary["version"])
		keyColor.Print("Last Updated: ")
		fmt.Printf("%v\n", summary["lastUpdated"])
		keyColor.Print("Spaces: ")
		fmt.Printf("%v\n", summary["spaceCount"])
		fmt.Println()

		if spaces, ok := summary["spaces"].(map[string]interface{}); ok {
			for spaceID, spaceInfo := range spaces {
				info := spaceInfo.(map[string]interface{})
				keyColor.Printf("Space %s:\n", spaceID)
				fmt.Printf("  Current Layout: %v\n", info["currentLayout"])
				fmt.Printf("  Cells: %v\n", info["cellCount"])
				fmt.Printf("  Windows: %v\n", info["windowCount"])
				fmt.Printf("  Focused Cell: %v\n", info["focusedCell"])
				fmt.Println()
			}
		}

		return nil
	},
}

// stateResetCmd resets runtime state
var stateResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Clear all runtime state",
	RunE: func(cmd *cobra.Command, args []string) error {
		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		if err := runtimeState.Reset(); err != nil {
			return fmt.Errorf("failed to reset state: %w", err)
		}

		successColor.Println("✓ State has been reset")
		return nil
	},
}

// MARK: - the-grid Focus Commands

// focusCmd is the parent command for focus subcommands
var focusCmd = &cobra.Command{
	Use:   "focus",
	Short: "Manage window focus",
	Long:  `Commands for moving focus between cells and windows.`,
}

// focusDirectionHelper is a helper function for directional focus commands
func focusDirectionHelper(direction gridTypes.Direction, wrapAround bool, extend bool) error {
	cfg, err := gridConfig.LoadConfig("")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	runtimeState, err := gridState.LoadState()
	if err != nil {
		return fmt.Errorf("failed to load state: %w", err)
	}

	c := client.NewClient(socketPath, timeout)
	defer c.Close()

	ctx := context.Background()

	// 1. Fetch server state ONCE
	snap, err := gridServer.Fetch(ctx, c)
	if err != nil {
		return fmt.Errorf("failed to fetch server state: %w", err)
	}

	// 2. Reconcile local state with server
	if err := gridReconcile.Sync(snap, runtimeState); err != nil {
		return fmt.Errorf("failed to reconcile state: %w", err)
	}

	// 3. Move focus
	opts := gridFocus.MoveFocusOpts{
		WrapAround: wrapAround,
		Extend:     extend,
	}
	windowID, err := gridFocus.MoveFocus(ctx, c, snap, cfg, runtimeState, direction, opts)
	if err != nil {
		return fmt.Errorf("failed to move focus: %w", err)
	}

	successColor.Printf("✓ Focused window: %d\n", windowID)
	return nil
}

// focusLeftCmd moves focus to the left cell
var focusLeftCmd = &cobra.Command{
	Use:   "left",
	Short: "Move focus to left cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor focus enabled")
		}
		return focusDirectionHelper(gridTypes.DirLeft, wrap, extend)
	},
}

// focusRightCmd moves focus to the right cell
var focusRightCmd = &cobra.Command{
	Use:   "right",
	Short: "Move focus to right cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor focus enabled")
		}
		return focusDirectionHelper(gridTypes.DirRight, wrap, extend)
	},
}

// focusUpCmd moves focus to the cell above
var focusUpCmd = &cobra.Command{
	Use:   "up",
	Short: "Move focus to cell above",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor focus enabled")
		}
		return focusDirectionHelper(gridTypes.DirUp, wrap, extend)
	},
}

// focusDownCmd moves focus to the cell below
var focusDownCmd = &cobra.Command{
	Use:   "down",
	Short: "Move focus to cell below",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor focus enabled")
		}
		return focusDirectionHelper(gridTypes.DirDown, wrap, extend)
	},
}

// moveWindowDirectionHelper is a helper function for directional window move commands
func moveWindowDirectionHelper(direction gridTypes.Direction, wrapAround bool, extend bool, windowID uint32) error {
	cfg, err := gridConfig.LoadConfig("")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	runtimeState, err := gridState.LoadState()
	if err != nil {
		return fmt.Errorf("failed to load state: %w", err)
	}

	c := client.NewClient(socketPath, timeout)
	defer c.Close()

	ctx := context.Background()

	// 1. Fetch server state ONCE
	snap, err := gridServer.Fetch(ctx, c)
	if err != nil {
		return fmt.Errorf("failed to fetch server state: %w", err)
	}

	// 2. Reconcile local state with server
	if err := gridReconcile.Sync(snap, runtimeState); err != nil {
		return fmt.Errorf("failed to reconcile state: %w", err)
	}

	// 3. Move window
	opts := gridWindow.MoveWindowOpts{
		WrapAround: wrapAround,
		Extend:     extend,
		WindowID:   windowID,
	}
	result, err := gridWindow.MoveWindow(ctx, c, snap, cfg, runtimeState, direction, opts)
	if err != nil {
		return fmt.Errorf("failed to move window: %w", err)
	}

	if result.CrossDisplay {
		successColor.Printf("Moved window %d: %s -> %s (cross-display to space %s)\n",
			result.WindowID, result.SourceCell, result.TargetCell, result.TargetSpace)
	} else {
		successColor.Printf("Moved window %d: %s -> %s\n",
			result.WindowID, result.SourceCell, result.TargetCell)
	}
	return nil
}

// windowMoveCmd is the parent command for window move operations
var windowMoveCmd = &cobra.Command{
	Use:   "move",
	Short: "Move window to adjacent cell",
	Long:  `Commands for moving windows between cells in the layout grid.`,
}

// windowMoveLeftCmd moves window to the left cell
var windowMoveLeftCmd = &cobra.Command{
	Use:   "left",
	Short: "Move window to left cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		windowID, _ := cmd.Flags().GetUint32("window-id")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor window move enabled")
		}
		return moveWindowDirectionHelper(gridTypes.DirLeft, wrap, extend, windowID)
	},
}

// windowMoveRightCmd moves window to the right cell
var windowMoveRightCmd = &cobra.Command{
	Use:   "right",
	Short: "Move window to right cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		windowID, _ := cmd.Flags().GetUint32("window-id")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor window move enabled")
		}
		return moveWindowDirectionHelper(gridTypes.DirRight, wrap, extend, windowID)
	},
}

// windowMoveUpCmd moves window to the cell above
var windowMoveUpCmd = &cobra.Command{
	Use:   "up",
	Short: "Move window to cell above",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		windowID, _ := cmd.Flags().GetUint32("window-id")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor window move enabled")
		}
		return moveWindowDirectionHelper(gridTypes.DirUp, wrap, extend, windowID)
	},
}

// windowMoveDownCmd moves window to the cell below
var windowMoveDownCmd = &cobra.Command{
	Use:   "down",
	Short: "Move window to cell below",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		wrap, _ := cmd.Flags().GetBool("wrap")
		extend, _ := cmd.Flags().GetBool("extend")
		windowID, _ := cmd.Flags().GetUint32("window-id")
		if extend {
			logging.Debug().Bool("extend", extend).Msg("cross-monitor window move enabled")
		}
		return moveWindowDirectionHelper(gridTypes.DirDown, wrap, extend, windowID)
	},
}

// focusNextCmd cycles focus to next window in cell
var focusNextCmd = &cobra.Command{
	Use:   "next",
	Short: "Cycle focus to next window in current cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		logging.Info().Str("cmd", "focus-next").Msg("starting")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to load state")
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to fetch server state")
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to reconcile")
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Cycle focus using local state
		windowID, err := gridFocus.CycleFocus(ctx, c, runtimeState, snap.SpaceID, true)
		if err != nil {
			logging.Error().Str("cmd", "focus-next").Err(err).Msg("failed to cycle")
			return fmt.Errorf("failed to cycle focus: %w", err)
		}

		if windowID == 0 {
			logging.Info().Str("cmd", "focus-next").Msg("no windows in cell")
			fmt.Println("No windows in current cell")
		} else {
			logging.Info().Str("cmd", "focus-next").Int("window_id", int(windowID)).Msg("focused window")
			successColor.Printf("✓ Focused window: %d\n", windowID)
		}
		return nil
	},
}

// focusPrevCmd cycles focus to previous window in cell
var focusPrevCmd = &cobra.Command{
	Use:   "prev",
	Short: "Cycle focus to previous window in current cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		logging.Info().Str("cmd", "focus-prev").Msg("starting")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			logging.Error().Str("cmd", "focus-prev").Err(err).Msg("failed to load state")
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			logging.Error().Str("cmd", "focus-prev").Err(err).Msg("failed to fetch server state")
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			logging.Error().Str("cmd", "focus-prev").Err(err).Msg("failed to reconcile")
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Cycle focus using local state
		windowID, err := gridFocus.CycleFocus(ctx, c, runtimeState, snap.SpaceID, false)
		if err != nil {
			logging.Error().Str("cmd", "focus-prev").Err(err).Msg("failed to cycle")
			return fmt.Errorf("failed to cycle focus: %w", err)
		}

		if windowID == 0 {
			logging.Info().Str("cmd", "focus-prev").Msg("no windows in cell")
			fmt.Println("No windows in current cell")
		} else {
			logging.Info().Str("cmd", "focus-prev").Int("window_id", int(windowID)).Msg("focused window")
			successColor.Printf("✓ Focused window: %d\n", windowID)
		}
		return nil
	},
}

// focusCellCmd jumps to specific cell
var focusCellCmd = &cobra.Command{
	Use:   "cell <id>",
	Short: "Jump focus to specific cell",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cellID := args[0]

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Focus the cell
		windowID, err := gridFocus.FocusCell(ctx, c, runtimeState, snap.SpaceID, cellID)
		if err != nil {
			return fmt.Errorf("failed to focus cell: %w", err)
		}

		successColor.Printf("✓ Focused cell %s (window: %d)\n", cellID, windowID)
		return nil
	},
}

// MARK: - the-grid Resize Commands

// resizeCmd is the parent command for resize subcommands
var gridResizeCmd = &cobra.Command{
	Use:   "resize",
	Short: "Resize windows in layout",
	Long:  `Commands for growing, shrinking, or resetting window splits.`,
}

// resizeAdjustCmd grows or shrinks focused window
var resizeAdjustCmd = &cobra.Command{
	Use:       "grow|shrink [amount]",
	Short:     "Grow or shrink focused window",
	Args:      cobra.RangeArgs(1, 2),
	ValidArgs: []string{"grow", "shrink"},
	RunE: func(cmd *cobra.Command, args []string) error {
		action := args[0]
		if action != "grow" && action != "shrink" {
			return fmt.Errorf("invalid action: %s (use 'grow' or 'shrink')", action)
		}

		delta := gridLayout.DefaultResizeAmount
		if len(args) > 1 {
			parsed, err := strconv.ParseFloat(args[1], 64)
			if err != nil {
				return fmt.Errorf("invalid amount: %w", err)
			}
			delta = parsed
		}
		if action == "shrink" {
			delta = -delta
		}

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Adjust split
		if err := gridLayout.AdjustFocusedSplit(ctx, c, snap, cfg, runtimeState, delta); err != nil {
			return fmt.Errorf("failed to resize: %w", err)
		}

		successColor.Printf("✓ Resized window (%s)\n", action)
		return nil
	},
}

// resizeResetCmd resets splits to equal
var resizeResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset splits to equal",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Reset splits
		resetAll, _ := cmd.Flags().GetBool("all")
		if resetAll {
			if err := gridLayout.ResetAllSplits(ctx, c, snap, cfg, runtimeState); err != nil {
				return fmt.Errorf("failed to reset all splits: %w", err)
			}
			successColor.Println("✓ Reset all splits to equal")
		} else {
			if err := gridLayout.ResetFocusedSplits(ctx, c, snap, cfg, runtimeState); err != nil {
				return fmt.Errorf("failed to reset splits: %w", err)
			}
			successColor.Println("✓ Reset focused cell splits to equal")
		}

		return nil
	},
}

// MARK: - the-grid Cell Commands

// cellCmd is the parent command for cell operations
var cellCmd = &cobra.Command{
	Use:   "cell",
	Short: "Cell operations",
	Long:  `Commands for managing windows within layout cells.`,
}

// cellSendCmd sends focused window to adjacent cell
var cellSendCmd = &cobra.Command{
	Use:   "send <direction>",
	Short: "Send focused window to adjacent cell",
	Long:  `Move the focused window to an adjacent cell in the specified direction (left, right, up, down).`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		direction, ok := gridTypes.ParseDirection(args[0])
		if !ok {
			return fmt.Errorf("invalid direction: %s (use left, right, up, or down)", args[0])
		}

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		ctx := context.Background()

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(snap, runtimeState); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Send window
		if err := gridCell.SendWindow(ctx, c, snap, cfg, runtimeState, direction); err != nil {
			return fmt.Errorf("failed to send window: %w", err)
		}

		successColor.Printf("✓ Sent window %s\n", direction.String())
		return nil
	},
}

// Helper function for formatting track sizes
func formatTrackSizes(tracks []gridTypes.TrackSize) string {
	var parts []string
	for _, t := range tracks {
		parts = append(parts, gridConfig.FormatTrackSize(t))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// MARK: - Render Command

// RenderWindow represents a window with normalized coordinates
type RenderWindow struct {
	ID     int     `json:"id"`
	X      float64 `json:"x"`      // Normalized 0.0-1.0
	Y      float64 `json:"y"`      // Normalized 0.0-1.0
	Width  float64 `json:"width"`  // Normalized 0.0-1.0
	Height float64 `json:"height"` // Normalized 0.0-1.0
}

// RenderLayout represents the layout configuration from stdin
type RenderLayout struct {
	Windows []RenderWindow `json:"windows"`
}

// renderCmd renders window layout from JSON stdin
var renderCmd = &cobra.Command{
	Use:   "render <space-id>",
	Short: "Render window layout from JSON configuration",
	Long: `Reads window layout configuration from stdin as JSON and positions
windows on the specified space. Coordinates are normalized (0.0-1.0) relative
to the display dimensions.

Example JSON input:
{
  "windows": [
    {"id": 12345, "x": 0.0, "y": 0.0, "width": 0.5, "height": 1.0},
    {"id": 67890, "x": 0.5, "y": 0.0, "width": 0.5, "height": 1.0}
  ]
}`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		spaceID := args[0]

		// 1. Read JSON from stdin
		var layout RenderLayout
		decoder := json.NewDecoder(os.Stdin)
		if err := decoder.Decode(&layout); err != nil {
			printError(fmt.Sprintf("Failed to parse input JSON: %v", err))
			return err
		}

		if len(layout.Windows) == 0 {
			printError("No windows specified in input")
			return fmt.Errorf("no windows specified")
		}

		// 2. Get current state to find the space and display
		state, err := getState()
		if err != nil {
			return err
		}

		// 3. Validate space exists
		_, exists := state.Spaces[spaceID]
		if !exists {
			printError(fmt.Sprintf("Space %s not found", spaceID))
			return fmt.Errorf("space not found: %s", spaceID)
		}

		// 4. Find the display for this space
		var targetDisplay *models.Display
		for _, display := range state.Displays {
			for _, sid := range display.GetSpaceIDs() {
				if sid == spaceID {
					targetDisplay = display
					break
				}
			}
			if targetDisplay != nil {
				break
			}
		}

		if targetDisplay == nil {
			printError(fmt.Sprintf("Could not find display for space %s", spaceID))
			return fmt.Errorf("display not found for space")
		}

		// Get display dimensions
		if targetDisplay.PixelWidth == nil || targetDisplay.PixelHeight == nil {
			printError("Display dimensions not available")
			return fmt.Errorf("display dimensions missing")
		}

		displayWidth := float64(*targetDisplay.PixelWidth)
		displayHeight := float64(*targetDisplay.PixelHeight)

		if !jsonOutput {
			infoColor.Printf("Rendering %d windows on space %s (display: %.0fx%.0f)\n",
				len(layout.Windows), spaceID, displayWidth, displayHeight)
		}

		// 5. Create client
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		// 6. Apply window positions
		var errors []string
		successCount := 0

		for _, win := range layout.Windows {
			// Convert normalized coordinates to absolute pixels
			absX := win.X * displayWidth
			absY := win.Y * displayHeight
			absWidth := win.Width * displayWidth
			absHeight := win.Height * displayHeight

			updates := map[string]interface{}{
				"x":       absX,
				"y":       absY,
				"width":   absWidth,
				"height":  absHeight,
				"spaceId": spaceID,
			}

			result, err := c.UpdateWindow(context.Background(), win.ID, updates)
			if err != nil {
				errors = append(errors, fmt.Sprintf("Window %d: %v", win.ID, err))
				continue
			}

			// Check for partial failures
			if result != nil {
				if errInfo, ok := result["error"]; ok && errInfo != nil {
					errors = append(errors, fmt.Sprintf("Window %d: server error", win.ID))
					continue
				}
			}

			successCount++
			if !jsonOutput {
				successColor.Printf("✓ Window %d positioned at (%.0f, %.0f) size %.0fx%.0f\n",
					win.ID, absX, absY, absWidth, absHeight)
			}
		}

		// 7. Report results
		if len(errors) > 0 {
			printError(fmt.Sprintf("Render completed with %d errors out of %d windows",
				len(errors), len(layout.Windows)))
			for _, e := range errors {
				fmt.Fprintln(os.Stderr, "  -", e)
			}
			return fmt.Errorf("%d window(s) failed to render", len(errors))
		}

		if !jsonOutput {
			successColor.Printf("\n✓ Successfully rendered %d windows on space %s\n",
				successCount, spaceID)
		} else {
			// Output summary in JSON mode
			summary := map[string]interface{}{
				"success":      true,
				"spaceId":      spaceID,
				"windowsTotal": len(layout.Windows),
				"windowsOk":    successCount,
				"windowsFail":  len(errors),
			}
			return printJSON(summary)
		}

		return nil
	},
}

func init() {
	// Global flags
	rootCmd.PersistentFlags().StringVar(&socketPath, "socket", client.DefaultSocketPath, "Unix socket path")
	rootCmd.PersistentFlags().DurationVar(&timeout, "timeout", client.DefaultTimeout, "Request timeout")
	rootCmd.PersistentFlags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	rootCmd.PersistentFlags().BoolVar(&noColor, "no-color", false, "Disable colored output")
	rootCmd.PersistentFlags().BoolVar(&debugMode, "debug", false, "Enable debug logging")

	// Add top-level commands
	rootCmd.AddCommand(pingCmd)
	rootCmd.AddCommand(infoCmd)
	rootCmd.AddCommand(dumpCmd)
	rootCmd.AddCommand(showCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(windowCmd)
	rootCmd.AddCommand(spaceCmd)
	rootCmd.AddCommand(renderCmd)

	// Add the-grid layout commands
	rootCmd.AddCommand(gridLayoutCmd)
	gridLayoutCmd.AddCommand(layoutListCmd)
	gridLayoutCmd.AddCommand(layoutShowCmd)
	gridLayoutCmd.AddCommand(layoutApplyCmd)
	gridLayoutCmd.AddCommand(layoutCycleCmd)
	gridLayoutCmd.AddCommand(layoutCurrentCmd)
	gridLayoutCmd.AddCommand(layoutReapplyCmd)

	// Add layout command flags
	layoutApplyCmd.Flags().String("space", "", "Space ID to apply layout to")
	layoutCycleCmd.Flags().String("space", "", "Space ID to cycle layout for")
	layoutCurrentCmd.Flags().String("space", "", "Space ID to check")

	// Add the-grid config commands
	rootCmd.AddCommand(gridConfigCmd)
	gridConfigCmd.AddCommand(configShowCmd)
	gridConfigCmd.AddCommand(configValidateCmd)
	gridConfigCmd.AddCommand(configInitCmd)

	// Add the-grid state commands
	rootCmd.AddCommand(gridStateCmd)
	gridStateCmd.AddCommand(stateShowCmd)
	gridStateCmd.AddCommand(stateResetCmd)

	// Add the-grid focus commands
	rootCmd.AddCommand(focusCmd)
	focusCmd.AddCommand(focusLeftCmd)
	focusCmd.AddCommand(focusRightCmd)
	focusCmd.AddCommand(focusUpCmd)
	focusCmd.AddCommand(focusDownCmd)
	focusCmd.AddCommand(focusNextCmd)
	focusCmd.AddCommand(focusPrevCmd)
	focusCmd.AddCommand(focusCellCmd)

	// Add focus command flags
	focusLeftCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
	focusRightCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
	focusUpCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
	focusDownCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")

	focusLeftCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")
	focusRightCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")
	focusUpCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")
	focusDownCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")

	// Add the-grid resize commands
	rootCmd.AddCommand(gridResizeCmd)
	gridResizeCmd.AddCommand(resizeAdjustCmd)
	gridResizeCmd.AddCommand(resizeResetCmd)

	// Add resize command flags
	resizeResetCmd.Flags().Bool("all", false, "Reset all cells, not just focused cell")

	// Add the-grid cell commands
	rootCmd.AddCommand(cellCmd)
	cellCmd.AddCommand(cellSendCmd)

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

	// Add list windows flags
	listWindowsCmd.Flags().Bool("all", false, "Show all windows including system UI and utility windows")

	// Add window subcommands
	windowCmd.AddCommand(windowGetCmd)
	windowCmd.AddCommand(windowFindCmd)
	windowCmd.AddCommand(windowUpdateCmd)
	windowCmd.AddCommand(windowToSpaceCmd)
	windowCmd.AddCommand(windowToDisplayCmd)
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
	windowCmd.AddCommand(windowMoveCmd)

	// Add window move subcommands
	windowMoveCmd.AddCommand(windowMoveLeftCmd)
	windowMoveCmd.AddCommand(windowMoveRightCmd)
	windowMoveCmd.AddCommand(windowMoveUpCmd)
	windowMoveCmd.AddCommand(windowMoveDownCmd)

	// Add flags for window move commands
	for _, cmd := range []*cobra.Command{windowMoveLeftCmd, windowMoveRightCmd, windowMoveUpCmd, windowMoveDownCmd} {
		cmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
		cmd.Flags().Bool("extend", false, "Extend to adjacent monitors")
		cmd.Flags().Uint32("window-id", 0, "Window ID to move (default: focused window)")
	}

	// Add space subcommands
	spaceCmd.AddCommand(spaceCreateCmd)
	spaceCmd.AddCommand(spaceDestroyCmd)
	spaceCmd.AddCommand(spaceFocusCmd)

	// Add flags for window update command
	windowUpdateCmd.Flags().Float64Var(&updateX, "x", 0, "X position (optional)")
	windowUpdateCmd.Flags().Float64Var(&updateY, "y", 0, "Y position (optional)")
	windowUpdateCmd.Flags().Float64Var(&updateWidth, "width", 0, "Width in pixels (optional)")
	windowUpdateCmd.Flags().Float64Var(&updateHeight, "height", 0, "Height in pixels (optional)")

	// Disable color if requested, enable debug logging if requested
	cobra.OnInitialize(func() {
		if noColor {
			color.NoColor = true
		}
		if debugMode {
			logging.SetDebug(true)
		}
	})
}

func main() {
	// Initialize logging
	logging.Init()
	defer logging.Close()

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

// filterWindows applies yabai-style filtering to exclude system UI and utility windows
func filterWindows(windows []*models.Window) []*models.Window {
	filtered := make([]*models.Window, 0, len(windows))

	for _, w := range windows {
		if shouldIncludeWindow(w) {
			filtered = append(filtered, w)
		}
	}

	return filtered
}

// shouldIncludeWindow determines if a window should be included in filtered results
// Implements yabai-style filtering logic
func shouldIncludeWindow(w *models.Window) bool {
	// Filter 1: Exclude windows with invalid frames (too small or zero-sized)
	// Also exclude very small windows (likely utility windows, icons, etc.)
	if w.GetWidth() < 100 || w.GetHeight() < 100 {
		return false
	}

	// Filter 2: Exclude windows that are not at normal level (level 0)
	// Popup menus, tooltips, etc. have higher levels
	// Level is interface{}, so we need to type-assert
	levelOK := false
	switch v := w.Level.(type) {
	case int:
		levelOK = (v == 0)
	case float64:
		levelOK = (v == 0.0)
	}
	if !levelOK {
		return false
	}

	// Filter 3: Check AX role/subrole (if available)
	// Only apply this filter if role data exists
	if w.Role != nil && *w.Role != "" {
		// Only include standard windows
		if *w.Role != "AXWindow" {
			return false
		}

		// Check subrole - exclude non-standard windows
		if w.Subrole != nil && *w.Subrole != "" {
			excludedSubroles := []string{
				"AXSystemDialog",
				"AXFloatingWindow",
				"AXUnknown",
			}

			for _, excluded := range excludedSubroles {
				if *w.Subrole == excluded {
					return false
				}
			}
		}
	}
	// Note: If role is nil/empty, we don't filter - this allows windows
	// that don't expose AX properties to still be shown

	// Filter 4: Exclude windows with parents (child windows, popups)
	if w.Parent != nil && *w.Parent != 0 {
		return false
	}

	// Filter 5: Exclude windows from system processes
	// This catches menu bar extras, notification center, etc.
	if w.AppName != nil && *w.AppName != "" {
		systemApps := []string{
			"Window Server",
			"Dock",
			"SystemUIServer",
			"ControlCenter",
			"Control Center",
			"NotificationCenter",
			"Notification Center",
			"Spotlight",
			"TextInputMenuAgent",
			"TextInputSwitcher",
			"Open and Save Panel Service",
			"CursorUIViewService",
			"PhotosPicker",
		}

		appName := *w.AppName
		for _, sysApp := range systemApps {
			if appName == sysApp {
				return false
			}
		}
	}

	// Also filter borders and similar utilities by checking window title
	if w.Title != nil && *w.Title != "" {
		title := *w.Title
		utilityTitles := []string{
			"borders",
			"Menubar",
			"Window Server",
		}

		for _, utilTitle := range utilityTitles {
			if title == utilTitle {
				return false
			}
		}
	}

	// Filter 6: Exclude windows with no space assignment
	// Windows without spaces are typically floating overlays or system utilities
	// that aren't meant to be managed (e.g., screenshot tools, global overlays)
	if len(w.Spaces) == 0 {
		return false
	}

	// Passed all filters
	return true
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
