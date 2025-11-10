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
