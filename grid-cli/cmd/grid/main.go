package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/ryanthedev/grid-cli/internal/client"
	gridCell "github.com/ryanthedev/grid-cli/internal/cell"
	gridConfig "github.com/ryanthedev/grid-cli/internal/config"
	gridFocus "github.com/ryanthedev/grid-cli/internal/focus"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	gridLayout "github.com/ryanthedev/grid-cli/internal/layout"
	"github.com/ryanthedev/grid-cli/internal/models"
	gridMouse "github.com/ryanthedev/grid-cli/internal/mouse"
	"github.com/ryanthedev/grid-cli/internal/mutex"
	"github.com/ryanthedev/grid-cli/internal/output"
	gridReconcile "github.com/ryanthedev/grid-cli/internal/reconcile"
	gridServer "github.com/ryanthedev/grid-cli/internal/server"
	gridState "github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/tracing"
	gridTypes "github.com/ryanthedev/grid-cli/internal/types"
	gridWindow "github.com/ryanthedev/grid-cli/internal/window"
	"github.com/ryanthedev/grid-cli/internal/xdg"
	"github.com/ryanthedev/grid-cli/internal/process"
	"github.com/ryanthedev/grid-cli/internal/enrichers"
	gridEdit "github.com/ryanthedev/grid-cli/internal/edit"
	gridRecord "github.com/ryanthedev/grid-cli/internal/record"
	"github.com/ryanthedev/grid-cli/internal/tmux"
	"gopkg.in/yaml.v3"
)

// Build-time version info (injected via ldflags)
var (
	Version = "dev"
	Commit  = "unknown"
)

func versionString() string {
	if Commit != "unknown" && len(Commit) >= 7 {
		return fmt.Sprintf("%s (%s)", Version, Commit[:7])
	}
	return Version
}

var (
	socketPath string
	timeout    time.Duration
	jsonOutput bool
	noColor    bool

	// Color functions
	successColor = color.New(color.FgGreen, color.Bold)
	errorColor   = color.New(color.FgRed, color.Bold)
	warnColor    = color.New(color.FgYellow, color.Bold)
	infoColor    = color.New(color.FgCyan)
	keyColor     = color.New(color.FgYellow)

	// Command span for tracing
	currentSpan *jsonlog.Span

	// CLI mutex for serializing commands (prevents race conditions with rapid hotkeys)
	cliMutex *mutex.CLIMutex
)

// rootCmd is the base command
var rootCmd = &cobra.Command{
	Use:   "thegrid",
	Short: "GridServer CLI - macOS window manager client",
	Long: `Grid is a command-line client for GridServer, a powerful macOS window manager.

It allows you to query window state, manipulate window positions and sizes,
and move windows between spaces and displays.`,
	Version: versionString(),
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		// Build args map with relevant command arguments
		argsMap := make(map[string]any)
		for _, arg := range args {
			if len(argsMap) < 5 { // Keep it minimal
				argsMap[fmt.Sprintf("arg%d", len(argsMap))] = arg
			}
		}

		// Start command span (include version for debugging)
		currentSpan = jsonlog.StartSpan("cmd", jsonlog.WithData(map[string]any{
			"cmd":     cmd.CommandPath(),
			"args":    argsMap,
			"version": Version,
		}))

		// Register span with tracing context
		tracing.SetCurrentSpan(currentSpan)

		// Acquire CLI mutex (serialize commands to prevent race conditions)
		// Skip for read-only/help commands that don't modify state
		if !shouldSkipMutex(cmd) {
			stateDir := filepath.Join(xdg.StateHome(), "thegrid")
			cliMutex = mutex.New(stateDir)
			if err := cliMutex.Lock(mutex.DefaultTimeout); err != nil {
				// Log the error but don't fail - better to risk a race than block completely
				jsonlog.Log("mutex.error", jsonlog.WithData(map[string]any{
					"err": err.Error(),
					"cmd": cmd.CommandPath(),
				}))
			}
		}
	},
	PersistentPostRun: func(cmd *cobra.Command, args []string) {
		// Release CLI mutex
		if cliMutex != nil {
			cliMutex.Unlock()
			cliMutex = nil
		}

		if currentSpan != nil {
			currentSpan.End()
			currentSpan = nil
		}
	},
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
		if version, ok := result["version"].(string); ok {
			commit := ""
			if c, ok := result["commit"].(string); ok && len(c) >= 7 {
				commit = c[:7]
			}
			if commit != "" {
				fmt.Printf("Server version: %s (%s)\n", version, commit)
			} else {
				fmt.Printf("Server version: %s\n", version)
			}
		}

		return nil
	},
}

// debugCmd is the parent command for diagnostic tools
var debugCmd = &cobra.Command{
	Use:    "debug",
	Short:  "Diagnostic tools for debugging",
	Hidden: true,
}

// debugBordersCmd tests border rendering by cycling through colors
var debugBordersCmd = &cobra.Command{
	Use:   "borders",
	Short: "Cycle active border through colors to test style updates",
	RunE: func(cmd *cobra.Command, args []string) error {
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		if err := c.DebugBorders(context.Background()); err != nil {
			printError(fmt.Sprintf("Debug borders failed: %v", err))
			return err
		}

		fmt.Println("Border test triggered - watch it cycle through colors...")
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
		ctx := context.Background()

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

		result, err := c.UpdateWindow(ctx, windowID, updates)
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
		ctx := context.Background()

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

		result, err := c.UpdateWindow(ctx, windowID, updates)
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
		ctx := context.Background()

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

		result, err := c.UpdateWindow(ctx, windowID, updates)
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
		ctx := context.Background()

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

		result, err := c.CallMethod(ctx, "window.setOpacity", params)
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
		ctx := context.Background()

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

		result, err := c.CallMethod(ctx, "window.fadeOpacity", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "window.getOpacity", params)
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
		ctx := context.Background()

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

		result, err := c.CallMethod(ctx, "window.setLayer", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "window.getLayer", params)
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
		ctx := context.Background()

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

		result, err := c.CallMethod(ctx, "window.setSticky", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "window.isSticky", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "window.minimize", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "window.unminimize", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"windowId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "window.isMinimized", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"displaySpaceId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "space.create", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"spaceId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "space.destroy", params)
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
		ctx := context.Background()

		params := map[string]interface{}{
			"spaceId": args[0],
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		result, err := c.CallMethod(ctx, "space.focus", params)
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
		ctx := context.Background()

		layoutID := args[0]
		spaceID, _ := cmd.Flags().GetString("space")

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

		// 1. Fetch server state for the target space
		var snap *gridServer.Snapshot
		if spaceID != "" {
			// Fetch snapshot specifically for the target space (gets correct windows)
			snap, err = gridServer.FetchForSpace(ctx, c, spaceID)
		} else {
			snap, err = gridServer.Fetch(ctx, c)
		}
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
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

// layoutCurrentCmd shows the current layout
var layoutCurrentCmd = &cobra.Command{
	Use:   "current",
	Short: "Show current layout for space",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		spaceID, _ := cmd.Flags().GetString("space")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		// If no space specified, get current from server using proper snapshot
		if spaceID == "" {
			c := client.NewClient(socketPath, timeout)
			defer c.Close()
			snap, err := gridServer.Fetch(ctx, c)
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

// layoutRefreshCmd refreshes layouts on all displays
var layoutRefreshCmd = &cobra.Command{
	Use:   "refresh",
	Short: "Refresh layouts on all displays",
	Long: `Refreshes layouts on all connected displays.

For each display, this command:
- Fetches the current window state
- Reconciles state (removes dead windows)
- Reapplies the existing layout if one was active, or applies the default layout

This is useful when windows have moved or displays have changed.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		// Log command invocation
		displayFilter, _ := cmd.Flags().GetString("display")
		jsonlog.Log("cli.invoke", jsonlog.WithData(map[string]any{
			"cmd":     "layout refresh",
			"display": displayFilter,
		}))

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

		// Build options
		opts := gridLayout.DefaultApplyOptions()
		opts.BaseSpacing = cfg.GetBaseSpacing()
		if settingsPadding, err := cfg.GetSettingsPadding(); err == nil {
			opts.SettingsPadding = settingsPadding
		}
		if settingsWindowSpacing, err := cfg.GetSettingsWindowSpacing(); err == nil {
			opts.SettingsWindowSpacing = settingsWindowSpacing
		}
		if displayFilter != "" {
			opts.DisplayFilter = displayFilter
		}

		// Refresh all displays (or filtered display)
		errors := gridLayout.RefreshAllDisplays(ctx, c, cfg, runtimeState, opts)

		// Report results
		if len(errors) > 0 {
			for _, e := range errors {
				errorColor.Printf("✗ %s (%s): %v\n", e.DisplayName, e.DisplayUUID, e.Err)
			}
			return fmt.Errorf("refresh failed on %d display(s)", len(errors))
		}

		if displayFilter != "" {
			successColor.Printf("✓ Refreshed layout on display %s\n", displayFilter)
		} else {
			successColor.Println("✓ Refreshed layouts on all displays")
		}
		return nil
	},
}

// layoutSaveCmd saves current runtime layout modifications to config.local.yaml
var layoutSaveCmd = &cobra.Command{
	Use:   "save",
	Short: "Save current layout proportions and cell modes to config",
	Long: `Saves runtime layout modifications (cell resize ratios and stack modes)
to config.local.yaml so they become the permanent defaults for this layout.

After saving, runtime ratios are cleared since the layout definition
now reflects those proportions.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

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

		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		spaceState := runtimeState.GetSpaceReadOnly(snap.SpaceID)
		if spaceState == nil {
			return fmt.Errorf("no layout applied for current space")
		}

		layoutID := spaceState.CurrentLayoutID
		if layoutID == "" {
			return fmt.Errorf("no layout applied for current space")
		}

		// Get the base layout (without overrides) to access original track definitions
		layout, err := cfg.GetLayout(layoutID)
		if err != nil {
			return fmt.Errorf("layout %q not found: %w", layoutID, err)
		}

		override := gridConfig.LayoutOverrideConfig{}
		hasChanges := false

		// Convert column ratios to track strings
		if len(spaceState.ColumnRatios) > 0 {
			columns := gridLayout.RatiosToTrackStrings(layout.Columns, spaceState.ColumnRatios)
			if override.Grid == nil {
				override.Grid = &gridConfig.GridConfig{}
			}
			override.Grid.Columns = columns
			hasChanges = true
		}

		// Convert row ratios to track strings
		if len(spaceState.RowRatios) > 0 {
			rows := gridLayout.RatiosToTrackStrings(layout.Rows, spaceState.RowRatios)
			if override.Grid == nil {
				override.Grid = &gridConfig.GridConfig{}
			}
			override.Grid.Rows = rows
			hasChanges = true
		}

		// Collect cell mode overrides
		for cellID, cellState := range spaceState.Cells {
			if cellState.StackMode != "" {
				if override.CellModes == nil {
					override.CellModes = make(map[string]gridTypes.StackMode)
				}
				override.CellModes[cellID] = cellState.StackMode
				hasChanges = true
			}
		}

		if !hasChanges {
			fmt.Println("No layout modifications to save")
			return nil
		}

		if err := gridConfig.SaveLayoutOverride(layoutID, override); err != nil {
			return fmt.Errorf("failed to save layout override: %w", err)
		}

		// Clear runtime ratios — they're now baked into config
		mutableSpace := runtimeState.GetSpace(snap.SpaceID)
		mutableSpace.ColumnRatios = nil
		mutableSpace.RowRatios = nil
		runtimeState.MarkUpdated()
		if err := runtimeState.Save(); err != nil {
			return fmt.Errorf("failed to save state: %w", err)
		}

		successColor.Printf("Saved layout %q overrides to config.local.yaml\n", layoutID)

		if override.Grid != nil {
			if len(override.Grid.Columns) > 0 {
				fmt.Printf("  columns: %v\n", override.Grid.Columns)
			}
			if len(override.Grid.Rows) > 0 {
				fmt.Printf("  rows: %v\n", override.Grid.Rows)
			}
		}
		if len(override.CellModes) > 0 {
			fmt.Printf("  cellModes: %v\n", override.CellModes)
		}

		return nil
	},
}

// layoutEditCmd opens $EDITOR to reorder/reorganize windows in cells
var layoutEditCmd = &cobra.Command{
	Use:   "edit",
	Short: "Edit window order in cells using $EDITOR",
	Long: `Opens your editor with the current window list. Reorder lines to
reorder windows, delete lines to close windows. In --all mode, move
lines between cell sections to move windows between cells.

Save and quit to apply changes. Quit without saving to abort.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()
		allCells, _ := cmd.Flags().GetBool("all")

		// Phase 1: Snapshot (with mutex)
		stateDir := filepath.Join(xdg.StateHome(), "thegrid")
		editMutex := mutex.New(stateDir)
		if err := editMutex.Lock(mutex.DefaultTimeout); err != nil {
			return fmt.Errorf("failed to acquire lock: %w", err)
		}

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			editMutex.Unlock()
			return fmt.Errorf("failed to load config: %w", err)
		}

		runtimeState, err := gridState.LoadState()
		if err != nil {
			editMutex.Unlock()
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			editMutex.Unlock()
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			editMutex.Unlock()
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// Initialize enrichers for window title enrichment
		registry := enrichers.NewRegistry()
		registry.RefreshCaches()
		process.RefreshProcessTree()
		defer registry.Cleanup()

		spaceState := runtimeState.GetSpaceReadOnly(snap.SpaceID)
		if spaceState == nil || spaceState.CurrentLayoutID == "" {
			editMutex.Unlock()
			return fmt.Errorf("no layout applied — run 'thegrid layout apply' first")
		}

		// Build cell info for the edit buffer
		var cells []gridEdit.CellInfo

		if allCells {
			// Get layout for cell bounds sorting
			layoutDef, err := cfg.GetLayout(spaceState.CurrentLayoutID)
			if err != nil {
				editMutex.Unlock()
				return fmt.Errorf("layout not found: %w", err)
			}
			calculated := gridLayout.CalculateLayout(layoutDef, snap.DisplayBounds, 0)
			sortedCellIDs := gridLayout.SortCellsByPosition(calculated.CellBounds)

			for _, cellID := range sortedCellIDs {
				cellState := spaceState.Cells[cellID]
				cell := gridEdit.CellInfo{CellID: cellID}
				if cellState != nil {
					for _, wid := range cellState.Windows {
						entry := gridEdit.WindowEntry{WID: wid, AppName: "unknown"}
						if w := snap.GetWindowByID(wid); w != nil {
							entry.AppName = w.AppName
							entry.Title = w.Title
							if enrichResult := registry.Enrich(w.BundleID, w.PID, w.Title); enrichResult != nil {
								if enrichResult.Title != "" {
									entry.Title = enrichResult.Title
								}
								if enrichResult.Subtitle != "" {
									entry.Subtitle = enrichResult.Subtitle
								}
							}
						}
						cell.Windows = append(cell.Windows, entry)
					}
				}
				cells = append(cells, cell)
			}
		} else {
			focusedCell := spaceState.FocusedCell
			if focusedCell == "" {
				editMutex.Unlock()
				return fmt.Errorf("no focused cell")
			}
			cellState := spaceState.Cells[focusedCell]
			cell := gridEdit.CellInfo{CellID: focusedCell}
			if cellState != nil {
				for _, wid := range cellState.Windows {
					entry := gridEdit.WindowEntry{WID: wid, AppName: "unknown"}
					if w := snap.GetWindowByID(wid); w != nil {
						entry.AppName = w.AppName
						entry.Title = w.Title
						if enrichResult := registry.Enrich(w.BundleID, w.PID, w.Title); enrichResult != nil {
							if enrichResult.Title != "" {
								entry.Title = enrichResult.Title
							}
							if enrichResult.Subtitle != "" {
								entry.Subtitle = enrichResult.Subtitle
							}
						}
					}
					cell.Windows = append(cell.Windows, entry)
				}
			}
			cells = append(cells, cell)
		}

		// Build buffer and write temp file
		var bufferContent string
		if allCells {
			bufferContent = gridEdit.BuildBufferAll(cells)
		} else {
			bufferContent = gridEdit.BuildBuffer(cells[0])
		}

		original := gridEdit.OriginalAssignments(cells)
		originalHash := gridEdit.HashContent([]byte(bufferContent))

		tmpFile, err := gridEdit.WriteTempFile(bufferContent)
		if err != nil {
			editMutex.Unlock()
			return fmt.Errorf("failed to create temp file: %w", err)
		}
		defer os.Remove(tmpFile)

		// Release mutex before opening editor
		editMutex.Unlock()

		// Phase 2: Editor (no mutex)
		editorErr := gridEdit.OpenEditor(tmpFile)

		// Read back the edited file
		editedBytes, err := os.ReadFile(tmpFile)
		if err != nil {
			return fmt.Errorf("failed to read edited file: %w", err)
		}

		// Check for no-op: editor error or unchanged content
		editedHash := gridEdit.HashContent(editedBytes)
		if editorErr != nil || originalHash == editedHash {
			if editorErr != nil {
				fmt.Println("Editor exited without saving — no changes applied")
			} else {
				fmt.Println("No changes detected")
			}
			return nil
		}

		// Phase 3: Apply (reacquire mutex)
		if err := editMutex.Lock(mutex.DefaultTimeout); err != nil {
			return fmt.Errorf("failed to reacquire lock: %w", err)
		}
		defer editMutex.Unlock()

		// Re-fetch fresh state
		snap, err = gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to re-fetch server state: %w", err)
		}

		runtimeState, err = gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to reload state: %w", err)
		}

		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// Parse the edited buffer
		var edited map[string][]uint32
		if allCells {
			edited, err = gridEdit.ParseBufferAll(string(editedBytes))
		} else {
			edited, err = gridEdit.ParseBufferSingle(string(editedBytes), cells[0].CellID)
		}
		if err != nil {
			return fmt.Errorf("failed to parse edited buffer: %w", err)
		}

		// Diff changes
		result := gridEdit.DiffChanges(original, edited)
		if !result.Changed {
			fmt.Println("No changes detected")
			return nil
		}

		// Close deleted windows
		for _, wid := range result.CloseWindows {
			if closeErr := c.CloseWindow(ctx, wid); closeErr != nil {
				warnColor.Printf("⚠ Failed to close window %d: %v\n", wid, closeErr)
			}
		}

		// Filter closed windows out of assignments
		closedSet := make(map[uint32]bool)
		for _, wid := range result.CloseWindows {
			closedSet[wid] = true
		}
		filteredAssignments := make(map[string][]uint32)
		for cellID, wids := range result.CellWindows {
			var filtered []uint32
			for _, wid := range wids {
				if !closedSet[wid] {
					filtered = append(filtered, wid)
				}
			}
			filteredAssignments[cellID] = filtered
		}

		// Apply new assignments
		runtimeState.SetWindowAssignments(snap.SpaceID, filteredAssignments)
		runtimeState.MarkUpdated()
		if err := runtimeState.Save(); err != nil {
			return fmt.Errorf("failed to save state: %w", err)
		}

		// Reapply layout
		opts := gridLayout.DefaultApplyOptions()
		opts.Strategy = gridTypes.AssignPreserve
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

		// Sync borders
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)
		gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), snap.FocusedWindowID, cfg)

		// Summary
		closedCount := len(result.CloseWindows)
		if closedCount > 0 {
			successColor.Printf("✓ Applied changes (closed %d window(s))\n", closedCount)
		} else {
			successColor.Println("✓ Applied changes")
		}

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

// configSourcesCmd shows which config files would be loaded
var configSourcesCmd = &cobra.Command{
	Use:   "sources",
	Short: "Show which config files would be loaded",
	RunE: func(cmd *cobra.Command, args []string) error {
		configHome := xdg.ConfigHome()
		configDirs := xdg.ConfigDirs()

		fmt.Printf("XDG_CONFIG_HOME: %s\n", configHome)
		if len(configDirs) > 0 {
			fmt.Printf("XDG_CONFIG_DIRS: %s\n", strings.Join(configDirs, ":"))
		}
		fmt.Println()
		fmt.Println("Config sources (in merge order):")

		sources := gridConfig.GetConfigSources()
		count := 1
		for _, src := range sources {
			if src.Exists {
				fmt.Printf("  %d. %s (%s)\n", count, src.Path, src.Type)
				count++
			}
		}

		return nil
	},
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

		return printYAML(cfg)
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

		if path == "" {
			sources := gridConfig.GetConfigSources()
			numExisting := 0
			for _, src := range sources {
				if src.Exists {
					numExisting++
				}
			}
			fmt.Printf("Config valid (%d sources merged)\n", numExisting)
		} else {
			successColor.Println("✓ Configuration is valid")
			fmt.Printf("  Layouts: %d\n", len(cfg.Layouts))
			fmt.Printf("  Spaces: %d\n", len(cfg.Spaces))
			fmt.Printf("  App Rules: %d\n", len(cfg.AppRules))
		}

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

// MARK: - Event Commands (Server→CLI callbacks)

// eventCmd is the parent command for server-initiated events
var eventCmd = &cobra.Command{
	Use:   "event",
	Short: "Handle server-initiated events",
	Long:  `Commands invoked by the server for event handling (e.g., border sync on click focus).`,
}

// eventFocusCmd handles external focus events from the server
var eventFocusCmd = &cobra.Command{
	Use:   "focus <windowID>",
	Short: "Sync borders for external focus change",
	Long:  `Called by the server when a window is focused externally (click, etc.).
Syncs border focus if the window is tileable.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		windowID, err := strconv.ParseUint(args[0], 10, 32)
		if err != nil {
			return fmt.Errorf("invalid window ID: %w", err)
		}

		ctx := context.Background()

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			jsonlog.Log("event.focus.err", jsonlog.WithMsg("config load failed"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return nil // Don't fail - borders are non-critical
		}

		// Skip if borders not enabled
		if cfg.Borders == nil || !cfg.Borders.GetEnabled() {
			return nil
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		// Get current snapshot
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			jsonlog.Log("event.focus.err", jsonlog.WithMsg("snapshot failed"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return nil
		}

		// Find window in snapshot
		window := snap.GetWindowByID(uint32(windowID))
		if window == nil {
			jsonlog.Log("event.focus.skip", jsonlog.WithMsg("window not found"), jsonlog.WithData(map[string]any{"wid": windowID}))
			return nil
		}

		// Check if tileable (has role AXWindow and standard subrole)
		if !window.IsTileable() {
			jsonlog.Log("event.focus.skip", jsonlog.WithMsg("not tileable"), jsonlog.WithData(map[string]any{"wid": windowID, "role": window.Role}))
			return nil
		}

		// Get display UUID for this window
		displayUUID := window.DisplayUUID
		if displayUUID == "" {
			displayUUID = snap.GetCurrentDisplayUUID()
		}

		// Sync border focus
		gridReconcile.SyncBorderFocus(ctx, c, displayUUID, uint32(windowID), cfg)
		jsonlog.Log("event.focus.ok", jsonlog.WithData(map[string]any{"wid": windowID, "display": displayUUID}))

		return nil
	},
}

// MARK: - the-grid Pick Commands

// pickCmd triggers the picker via RPC to the server
var pickCmd = &cobra.Command{
	Use:   "pick",
	Short: "Open the unified picker",
	Long: `Triggers the picker UI via the server.
The server shows the picker window, user selects,
server executes the action.`,
	RunE: runPick,
}

// runPick sends pick.show RPC to the server and prints the result
func runPick(cmd *cobra.Command, args []string) error {
	ctx := context.Background()
	c := client.NewClient(socketPath, timeout)
	defer c.Close()

	result, err := c.CallMethod(ctx, "pick.show", nil)
	if err != nil {
		return fmt.Errorf("pick failed: %w", err)
	}

	// Check if cancelled
	if cancelled, ok := result["cancelled"].(bool); ok && cancelled {
		return nil
	}

	// Print selected item info for scripting
	if selected, ok := result["selected"].(map[string]interface{}); ok {
		if id, ok := selected["id"].(string); ok {
			fmt.Printf("%s", id)
			if title, ok := selected["title"].(string); ok {
				fmt.Printf("\t%s", title)
			}
			fmt.Println()
		}
	}

	return nil
}


// MARK: - the-grid Focus Commands

// focusCmd is the parent command for focus subcommands
var focusCmd = &cobra.Command{
	Use:   "focus",
	Short: "Manage window focus",
	Long:  `Commands for moving focus between cells and windows.`,
}

// focusDirectionHelper is a helper function for directional focus commands
func focusDirectionHelper(direction gridTypes.Direction, wrapAround bool, extend bool, mouse bool) error {
	ctx := context.Background()

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

	// 1. Fetch server state ONCE
	snap, err := gridServer.Fetch(ctx, c)
	if err != nil {
		return fmt.Errorf("failed to fetch server state: %w", err)
	}

	// 2. Reconcile local state with server
	if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
		return fmt.Errorf("failed to reconcile state: %w", err)
	}

	// 3. Move focus
	opts := gridFocus.MoveFocusOpts{
		WrapAround: wrapAround,
		Extend:     extend,
	}
	previousFocusedID := snap.FocusedWindowID
	windowID, err := gridFocus.MoveFocus(ctx, c, snap, cfg, runtimeState, direction, opts)
	if err != nil {
		return fmt.Errorf("failed to move focus: %w", err)
	}

	successColor.Printf("✓ Focused window: %d\n", windowID)

	// Warn if focus didn't actually change (likely stale state)
	if windowID == previousFocusedID && previousFocusedID != 0 {
		warnColor.Printf("⚠ Focus unchanged - runtime state may be stale. Try: thegrid layout refresh\n")
	}

	// Sync borders after focus change (cell assignments may have changed)
	gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

	// Sync border focus so borders update even if assignments didn't change
	gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), windowID, cfg)

	// 4. Optionally warp mouse to focused window
	if mouse && windowID != 0 {
		if err := gridMouse.WarpToWindow(ctx, c, windowID); err != nil {
			// Warn but don't fail - focus succeeded
			errorColor.Printf("⚠ Mouse warp failed: %v\n", err)
		}
	}

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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("focus.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return focusDirectionHelper(gridTypes.DirLeft, wrap, extend, mouse)
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("focus.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return focusDirectionHelper(gridTypes.DirRight, wrap, extend, mouse)
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("focus.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return focusDirectionHelper(gridTypes.DirUp, wrap, extend, mouse)
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("focus.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return focusDirectionHelper(gridTypes.DirDown, wrap, extend, mouse)
	},
}

// moveWindowDirectionHelper is a helper function for directional window move commands
func moveWindowDirectionHelper(direction gridTypes.Direction, wrapAround bool, extend bool, windowID uint32, mouse bool) error {
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
	if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
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

	// Sync borders after window move (cell assignments changed)
	// For cross-display moves, border sync is handled inside moveWindowCrossDisplay()
	// with the correct target display UUID. Only sync here for same-display moves.
	if !result.CrossDisplay {
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)
		gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), result.WindowID, cfg)
	}

	// Optionally warp mouse to moved window
	if mouse && result.WindowID != 0 {
		if err := gridMouse.WarpToWindow(ctx, c, result.WindowID); err != nil {
			errorColor.Printf("⚠ Mouse warp failed: %v\n", err)
		}
	}

	return nil
}

// swapWindowDirectionHelper is a helper function for directional window swap commands
func swapWindowDirectionHelper(direction gridTypes.Direction, mouse bool) error {
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
	if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
		return fmt.Errorf("failed to reconcile state: %w", err)
	}

	// 3. Swap window
	if err := gridCell.SwapWindow(ctx, c, snap, cfg, runtimeState, direction); err != nil {
		return fmt.Errorf("failed to swap window: %w", err)
	}

	successColor.Printf("Swapped window %s\n", direction.String())

	// Sync borders after window swap (cell assignments changed)
	gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

	// Sync border focus so the border appears on the focused window
	gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), snap.FocusedWindowID, cfg)

	// Optionally warp mouse to focused window
	if mouse && snap.FocusedWindowID != 0 {
		if err := gridMouse.WarpToWindow(ctx, c, snap.FocusedWindowID); err != nil {
			errorColor.Printf("⚠ Mouse warp failed: %v\n", err)
		}
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("move.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return moveWindowDirectionHelper(gridTypes.DirLeft, wrap, extend, windowID, mouse)
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("move.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return moveWindowDirectionHelper(gridTypes.DirRight, wrap, extend, windowID, mouse)
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("move.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return moveWindowDirectionHelper(gridTypes.DirUp, wrap, extend, windowID, mouse)
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
		mouse, _ := cmd.Flags().GetBool("mouse")
		if extend {
			jsonlog.Log("move.cross_monitor", jsonlog.WithData(map[string]any{"extend": extend}))
		}
		return moveWindowDirectionHelper(gridTypes.DirDown, wrap, extend, windowID, mouse)
	},
}

// windowSwapCmd is the parent command for window swap operations
var windowSwapCmd = &cobra.Command{
	Use:   "swap",
	Short: "Swap window with adjacent window in cell",
	Long: `Commands for swapping window positions within the same cell.
Direction is interpreted based on the cell's stack mode:
- vertical stacking: up/down swap with adjacent windows
- horizontal stacking: left/right swap with adjacent windows
- tabs: left/right cycle through window order
All directions wrap around at edges.`,
}

// windowSwapLeftCmd swaps window with the one to its left
var windowSwapLeftCmd = &cobra.Command{
	Use:   "left",
	Short: "Swap with window to the left (or previous in stack)",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		mouse, _ := cmd.Flags().GetBool("mouse")
		return swapWindowDirectionHelper(gridTypes.DirLeft, mouse)
	},
}

// windowSwapRightCmd swaps window with the one to its right
var windowSwapRightCmd = &cobra.Command{
	Use:   "right",
	Short: "Swap with window to the right (or next in stack)",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		mouse, _ := cmd.Flags().GetBool("mouse")
		return swapWindowDirectionHelper(gridTypes.DirRight, mouse)
	},
}

// windowSwapUpCmd swaps window with the one above
var windowSwapUpCmd = &cobra.Command{
	Use:   "up",
	Short: "Swap with window above (or previous in stack)",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		mouse, _ := cmd.Flags().GetBool("mouse")
		return swapWindowDirectionHelper(gridTypes.DirUp, mouse)
	},
}

// windowSwapDownCmd swaps window with the one below
var windowSwapDownCmd = &cobra.Command{
	Use:   "down",
	Short: "Swap with window below (or next in stack)",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		mouse, _ := cmd.Flags().GetBool("mouse")
		return swapWindowDirectionHelper(gridTypes.DirDown, mouse)
	},
}

// focusNextCmd cycles focus to next window in cell
var focusNextCmd = &cobra.Command{
	Use:   "next",
	Short: "Cycle focus to next window in current cell",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		jsonlog.Log("focus.next.start")
		mouse, _ := cmd.Flags().GetBool("mouse")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			jsonlog.Log("err.focus_next", jsonlog.WithMsg("failed to load state"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()


		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			jsonlog.Log("err.focus_next", jsonlog.WithMsg("failed to fetch server state"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Load config for border sync
		cfg, _ := gridConfig.LoadConfig("")

		// 3. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			jsonlog.Log("err.focus_next", jsonlog.WithMsg("failed to reconcile"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 4. Cycle focus using local state
		windowID, err := gridFocus.CycleFocus(ctx, c, runtimeState, snap.SpaceID, true)
		if err != nil {
			jsonlog.Log("err.focus_next", jsonlog.WithMsg("failed to cycle"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to cycle focus: %w", err)
		}

		if windowID == 0 {
			jsonlog.Log("focus.next.empty")
			fmt.Println("No windows in current cell")
		} else {
			jsonlog.Log("focus.next.done", jsonlog.WithData(map[string]any{"wid": windowID}))
			successColor.Printf("✓ Focused window: %d\n", windowID)

			// Sync borders after focus change
			gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

			// Sync border focus so borders update even if assignments didn't change
			gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), windowID, cfg)

			// 4. Optionally warp mouse to focused window
			if mouse {
				if err := gridMouse.WarpToWindow(ctx, c, windowID); err != nil {
					errorColor.Printf("⚠ Mouse warp failed: %v\n", err)
				}
			}
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
		ctx := context.Background()

		jsonlog.Log("focus.prev.start")
		mouse, _ := cmd.Flags().GetBool("mouse")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			jsonlog.Log("err.focus_prev", jsonlog.WithMsg("failed to load state"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()


		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			jsonlog.Log("err.focus_prev", jsonlog.WithMsg("failed to fetch server state"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Load config for border sync
		cfg, _ := gridConfig.LoadConfig("")

		// 3. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			jsonlog.Log("err.focus_prev", jsonlog.WithMsg("failed to reconcile"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 4. Cycle focus using local state
		windowID, err := gridFocus.CycleFocus(ctx, c, runtimeState, snap.SpaceID, false)
		if err != nil {
			jsonlog.Log("err.focus_prev", jsonlog.WithMsg("failed to cycle"), jsonlog.WithData(map[string]any{"err": err.Error()}))
			return fmt.Errorf("failed to cycle focus: %w", err)
		}

		if windowID == 0 {
			jsonlog.Log("focus.prev.empty")
			fmt.Println("No windows in current cell")
		} else {
			jsonlog.Log("focus.prev.done", jsonlog.WithData(map[string]any{"wid": windowID}))
			successColor.Printf("✓ Focused window: %d\n", windowID)

			// Sync borders after focus change
			gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

			// Sync border focus so borders update even if assignments didn't change
			gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), windowID, cfg)

			// 4. Optionally warp mouse to focused window
			if mouse {
				if err := gridMouse.WarpToWindow(ctx, c, windowID); err != nil {
					errorColor.Printf("⚠ Mouse warp failed: %v\n", err)
				}
			}
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
		ctx := context.Background()

		cellID := args[0]
		mouse, _ := cmd.Flags().GetBool("mouse")

		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()


		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Load config for border sync
		cfg, _ := gridConfig.LoadConfig("")

		// 3. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 4. Focus the cell
		windowID, err := gridFocus.FocusCell(ctx, c, runtimeState, snap.SpaceID, cellID)
		if err != nil {
			return fmt.Errorf("failed to focus cell: %w", err)
		}

		successColor.Printf("✓ Focused cell %s (window: %d)\n", cellID, windowID)

		// Sync borders after focus change
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

		// Sync border focus so borders update even if assignments didn't change
		gridReconcile.SyncBorderFocus(ctx, c, snap.GetCurrentDisplayUUID(), windowID, cfg)

		// 4. Optionally warp mouse to focused window
		if mouse && windowID != 0 {
			if err := gridMouse.WarpToWindow(ctx, c, windowID); err != nil {
				errorColor.Printf("⚠ Mouse warp failed: %v\n", err)
			}
		}

		return nil
	},
}

// focusInfoCmd outputs JSON with all active/focused state information
var focusInfoCmd = &cobra.Command{
	Use:   "info",
	Short: "Output JSON with all active/focused state information",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		// Load runtime state
		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		// Load config
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		// Create client
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		// Fetch server state
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// Reconcile state
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// Get space state
		spaceState := runtimeState.GetSpaceReadOnly(snap.SpaceID)
		if spaceState == nil {
			return fmt.Errorf("no state for space %s", snap.SpaceID)
		}

		// Get layout ID
		layoutID := spaceState.CurrentLayoutID

		// Calculate cell bounds
		var cellBounds map[string]client.CellRect
		var focusedCellBounds *client.CellRect
		if layoutID != "" {
			layoutDef, err := cfg.GetLayout(layoutID)
			if err == nil && layoutDef != nil {
				cellBounds = gridReconcile.CalculateCellBounds(layoutDef, snap, spaceState)

				// Get focused cell bounds
				if spaceState.FocusedCell != "" && cellBounds != nil {
					if bounds, ok := cellBounds[spaceState.FocusedCell]; ok {
						focusedCellBounds = &bounds
					}
				}
			}
		}

		// Build output structure
		output := map[string]interface{}{
			"activeSpaceID":      snap.SpaceID,
			"activeDisplayUUID":  snap.GetCurrentDisplayUUID(),
			"focusedWindowID":    snap.FocusedWindowID,
			"focusedCell":        spaceState.FocusedCell,
			"layoutID":           layoutID,
			"cellBounds":         cellBounds,
			"focusedCellBounds":  focusedCellBounds,
		}

		return printJSON(output)
	},
}

// MARK: - Mouse Commands

// mouseCmd is the parent command for mouse subcommands
var mouseCmd = &cobra.Command{
	Use:   "mouse",
	Short: "Control mouse cursor position",
	Long:  `Commands for warping the mouse cursor to windows.`,
}

// mouseCenterCmd warps mouse to currently focused window
var mouseCenterCmd = &cobra.Command{
	Use:   "center",
	Short: "Move mouse cursor to center of focused window",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		c := client.NewClient(socketPath, timeout)
		defer c.Close()


		// Get current state to find focused window
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		if snap.FocusedWindowID == 0 {
			return fmt.Errorf("no focused window")
		}

		// Warp mouse to focused window
		if err := gridMouse.WarpToWindow(ctx, c, snap.FocusedWindowID); err != nil {
			return fmt.Errorf("failed to warp mouse: %w", err)
		}

		successColor.Printf("✓ Mouse moved to window %d\n", snap.FocusedWindowID)
		return nil
	},
}

// mouseWarpCmd warps mouse to a specific window
var mouseWarpCmd = &cobra.Command{
	Use:   "warp <window-id>",
	Short: "Move mouse cursor to center of specified window",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		windowID, err := strconv.ParseUint(args[0], 10, 32)
		if err != nil {
			return fmt.Errorf("invalid window ID: %v", err)
		}

		c := client.NewClient(socketPath, timeout)
		defer c.Close()


		// Warp mouse to specified window
		if err := gridMouse.WarpToWindow(ctx, c, uint32(windowID)); err != nil {
			return fmt.Errorf("failed to warp mouse: %w", err)
		}

		successColor.Printf("✓ Mouse moved to window %d\n", windowID)
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
	Use:     "grow [amount]",
	Aliases: []string{"shrink"},
	Short:   "Grow or shrink focused window",
	Args:    cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		action := cmd.CalledAs()

		delta := gridLayout.DefaultResizeAmount
		if len(args) > 0 {
			parsed, err := strconv.ParseFloat(args[0], 64)
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

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Adjust split
		if err := gridLayout.AdjustFocusedSplit(ctx, c, snap, cfg, runtimeState, delta); err != nil {
			return fmt.Errorf("failed to resize: %w", err)
		}

		successColor.Printf("✓ Resized window (%s)\n", action)

		// Sync borders after resize (bounds changed)
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

		return nil
	},
}

// resizeResetCmd resets splits to equal
var resizeResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset splits to equal",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

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


		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Reset splits or cell ratios
		resetAll, _ := cmd.Flags().GetBool("all")
		resetCells, _ := cmd.Flags().GetBool("cells")

		if resetCells {
			// Reset cell/track ratios
			if err := gridLayout.ResetCellRatios(ctx, c, snap, cfg, runtimeState); err != nil {
				return fmt.Errorf("failed to reset cell ratios: %w", err)
			}
			successColor.Println("✓ Reset cell ratios to layout defaults")
		} else if resetAll {
			if err := gridLayout.ResetAllSplits(ctx, c, snap, cfg, runtimeState); err != nil {
				return fmt.Errorf("failed to reset all splits: %w", err)
			}
			successColor.Println("✓ Reset all window splits to equal")
		} else {
			if err := gridLayout.ResetFocusedSplits(ctx, c, snap, cfg, runtimeState); err != nil {
				return fmt.Errorf("failed to reset splits: %w", err)
			}
			successColor.Println("✓ Reset focused cell window splits to equal")
		}

		// Sync borders after resize reset (bounds changed)
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

		return nil
	},
}

// resizeCellCmd adjusts cell boundaries
var resizeCellCmd = &cobra.Command{
	Use:   "cell <direction> [amount]",
	Short: "Resize cell boundary in direction",
	Long: `Resize the focused cell's boundary in the specified direction.

Directions: left, right, up, down
Amount: ratio change (default 0.1 = 10%)

Examples:
  grid resize cell right 0.1   # Grow cell rightward by 10%
  grid resize cell left 0.05   # Grow cell leftward by 5%
  grid resize cell up          # Grow cell upward by default amount`,
	Args:      cobra.RangeArgs(1, 2),
	ValidArgs: []string{"left", "right", "up", "down"},
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		direction := args[0]
		if direction != "left" && direction != "right" && direction != "up" && direction != "down" {
			return fmt.Errorf("invalid direction: %s (use left, right, up, or down)", direction)
		}

		delta := gridLayout.DefaultResizeAmount
		if len(args) > 1 {
			parsed, err := strconv.ParseFloat(args[1], 64)
			if err != nil {
				return fmt.Errorf("invalid amount: %w", err)
			}
			delta = parsed
		}

		// DEBUG: timing instrumentation
		configSpan := jsonlog.StartSpan("resize.load_config")
		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			configSpan.EndWithError(err.Error())
			return fmt.Errorf("failed to load config: %w", err)
		}
		configSpan.End()

		stateSpan := jsonlog.StartSpan("resize.load_state")
		runtimeState, err := gridState.LoadState()
		if err != nil {
			stateSpan.EndWithError(err.Error())
			return fmt.Errorf("failed to load state: %w", err)
		}
		stateSpan.End()

		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		// 1. Fetch server state ONCE
		fetchSpan := jsonlog.StartSpan("resize.fetch")
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			fetchSpan.EndWithError(err.Error())
			return fmt.Errorf("failed to fetch server state: %w", err)
		}
		fetchSpan.End()

		// 2. Reconcile local state with server
		reconcileSpan := jsonlog.StartSpan("resize.reconcile")
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			reconcileSpan.EndWithError(err.Error())
			return fmt.Errorf("failed to reconcile state: %w", err)
		}
		reconcileSpan.End()

		// 3. Adjust cell boundary
		adjustSpan := jsonlog.StartSpan("resize.adjust")
		if err := gridLayout.AdjustCellBoundary(ctx, c, snap, cfg, runtimeState, direction, delta); err != nil {
			adjustSpan.EndWithError(err.Error())
			return fmt.Errorf("failed to resize cell: %w", err)
		}
		adjustSpan.End()

		successColor.Printf("✓ Resized cell (%s)\n", direction)

		// Sync borders after cell resize (bounds changed)
		borderSpan := jsonlog.StartSpan("resize.sync_borders_2")
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)
		borderSpan.End()

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
		ctx := context.Background()

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

		// 1. Fetch server state ONCE
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Send window
		if err := gridCell.SendWindow(ctx, c, snap, cfg, runtimeState, direction); err != nil {
			return fmt.Errorf("failed to send window: %w", err)
		}

		successColor.Printf("✓ Sent window %s\n", direction.String())

		// Sync borders after cell send (assignments changed)
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

		return nil
	},
}

// cellModeCmd sets or cycles the stack mode for the focused cell
var cellModeCmd = &cobra.Command{
	Use:   "mode [mode]",
	Short: "Set or cycle the stack mode for focused cell",
	Long: `Set or cycle the stack mode for the currently focused cell.

Without arguments, cycles through: vertical → horizontal → tabs → vertical
With an argument, sets the mode directly.

Valid modes: vertical, horizontal, tabs`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		var targetMode gridTypes.StackMode
		if len(args) > 0 {
			mode, err := gridCell.ParseStackMode(args[0])
			if err != nil {
				return err
			}
			targetMode = mode
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

		// 1. Fetch server state
		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// 2. Reconcile local state with server
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// 3. Set mode
		cellID, newMode, err := gridCell.SetMode(ctx, c, snap, cfg, runtimeState, targetMode)
		if err != nil {
			return fmt.Errorf("failed to set mode: %w", err)
		}

		// Save state to persist the mode change
		if err := runtimeState.Save(); err != nil {
			return fmt.Errorf("failed to save state: %w", err)
		}

		successColor.Printf("✓ Cell %q mode: %s\n", cellID, newMode)

		// Sync borders after cell mode change (tabs render differently)
		gridReconcile.SyncBorders(ctx, c, snap, runtimeState, cfg)

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
		ctx := context.Background()

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

			result, err := c.UpdateWindow(ctx, win.ID, updates)
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

// MARK: - Record Command

// recordCmd captures screen regions as GIF/MP4/WebM/MOV
var recordCmd = &cobra.Command{
	Use:   "record [target] [id]",
	Short: "Record a cell, window, screen, or all displays",
	Long: `Record a screen region as GIF, MP4, WebM, or MOV.

Targets:
  cell [id]     Record focused cell or specific cell (default)
  window [id]   Record focused window or specific window
  screen [n]    Record current display or display N (1=main)
  all           Record all displays stitched together

Examples:
  thegrid record                       # Record focused cell as GIF (5s)
  thegrid record cell main -d 10       # Record cell "main" for 10s
  thegrid record window -f mp4 -d 3    # Record focused window as MP4
  thegrid record screen -d 3           # Record current screen
  thegrid record all -f mp4 -d 3       # Record all monitors stitched
  thegrid record --follow -d 15        # Record screen, crop follows focused cell`,
	Args: cobra.MaximumNArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		// Parse target
		target, err := gridRecord.ParseTarget(args)
		if err != nil {
			return err
		}

		// Parse flags
		duration, _ := cmd.Flags().GetInt("duration")
		outputPath, _ := cmd.Flags().GetString("output")
		format, _ := cmd.Flags().GetString("format")
		fps, _ := cmd.Flags().GetInt("fps")
		width, _ := cmd.Flags().GetInt("width")
		qualityStr, _ := cmd.Flags().GetString("quality")
		countdown, _ := cmd.Flags().GetInt("countdown")
		cursor, _ := cmd.Flags().GetBool("cursor")
		openAfter, _ := cmd.Flags().GetBool("open")
		follow, _ := cmd.Flags().GetBool("follow")

		quality := gridRecord.ParseQuality(qualityStr)

		// Fetch server state
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		snap, err := gridServer.Fetch(ctx, c)
		if err != nil {
			return fmt.Errorf("failed to fetch server state: %w", err)
		}

		// Load runtime state and config (needed for cell targets)
		runtimeState, err := gridState.LoadState()
		if err != nil {
			return fmt.Errorf("failed to load state: %w", err)
		}

		cfg, err := gridConfig.LoadConfig("")
		if err != nil {
			return fmt.Errorf("failed to load config: %w", err)
		}

		// Reconcile
		if err := gridReconcile.Sync(ctx, c, snap, runtimeState, cfg); err != nil {
			return fmt.Errorf("failed to reconcile state: %w", err)
		}

		// Follow mode: override target to current screen
		if follow {
			if !gridRecord.FFmpegAvailable() {
				return fmt.Errorf("--follow requires ffmpeg: %s", gridRecord.InstallHint())
			}
			target = gridRecord.Target{Type: gridRecord.TargetScreen}
		}

		// Resolve target to pixel regions
		resolved, err := gridRecord.ResolveTarget(target, snap, runtimeState, cfg)
		if err != nil {
			return err
		}

		if !jsonOutput {
			if follow {
				infoColor.Printf("Recording %s with --follow (%.0fx%.0f)", resolved.Label, resolved.Regions[0].Width, resolved.Regions[0].Height)
			} else {
				infoColor.Printf("Recording %s (%.0fx%.0f)", resolved.Label, resolved.Regions[0].Width, resolved.Regions[0].Height)
				if len(resolved.Regions) > 1 {
					fmt.Printf(" + %d more regions", len(resolved.Regions)-1)
				}
			}
			fmt.Printf(" for %ds as %s\n", duration, format)
		}

		// Countdown
		if countdown > 0 && !jsonOutput {
			for i := countdown; i > 0; i-- {
				warnColor.Printf("%d...\n", i)
				time.Sleep(time.Second)
			}
		}

		if !jsonOutput {
			infoColor.Println("Recording...")
		}

		recordingDir := cfg.Settings.Recording.OutputDir
		if recordingDir != "" {
			if err := os.MkdirAll(recordingDir, 0o755); err != nil {
				return fmt.Errorf("failed to create recording output directory: %w", err)
			}
		}

		opts := gridRecord.Options{
			Duration:  duration,
			Output:    outputPath,
			OutputDir: recordingDir,
			Format:    format,
			FPS:       fps,
			Width:     width,
			Quality:   quality,
			Countdown: countdown,
			Cursor:    cursor,
			Open:      openAfter,
			Follow:    follow,
		}
		if follow {
			opts.FollowCtx = &gridRecord.FollowContext{
				Client: c,
				Config: cfg,
			}
		}

		result, err := gridRecord.Record(ctx, resolved, opts)
		if err != nil {
			return err
		}

		if jsonOutput {
			return printJSON(result)
		}

		successColor.Printf("✓ Saved: %s (%s, %s)\n", result.FilePath, result.Format, humanSize(result.Size))

		// Open file if requested — prefer GridViewer, fall back to system open
		if openAfter {
			if viewerPath, err := findViewerExecutable(); err == nil {
				exec.Command(viewerPath, result.FilePath).Start()
			} else {
				exec.Command("open", result.FilePath).Start()
			}
		}

		return nil
	},
}

// MARK: - View Command

// findViewerExecutable locates the grid-viewer binary by checking standard locations.
func findViewerExecutable() (string, error) {
	var searchPaths []string

	// 1. XDG state home: ~/.local/state/thegrid/grid-viewer
	stateDir := filepath.Join(xdg.StateHome(), "thegrid")
	searchPaths = append(searchPaths, filepath.Join(stateDir, "grid-viewer"))

	// 2. Same directory as current executable
	if execPath, err := os.Executable(); err == nil {
		searchPaths = append(searchPaths, filepath.Join(filepath.Dir(execPath), "grid-viewer"))
	}

	// 3. System PATH lookup
	if pathExec, err := exec.LookPath("grid-viewer"); err == nil {
		searchPaths = append(searchPaths, pathExec)
	}

	for _, path := range searchPaths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		if info.Mode()&0111 != 0 {
			return path, nil
		}
	}

	return "", fmt.Errorf("grid-viewer not found; build with: make viewer")
}

// viewCmd opens a file in the GridViewer
var viewCmd = &cobra.Command{
	Use:   "view <file>",
	Short: "Open a file in the GridViewer",
	Long:  `Open an image, GIF, or video in the floating GridViewer window.`,
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		// Expand ~ and resolve to absolute path
		filePath, err := filepath.Abs(gridConfig.ExpandTilde(args[0]))
		if err != nil {
			return fmt.Errorf("invalid path: %w", err)
		}
		if _, err := os.Stat(filePath); err != nil {
			return fmt.Errorf("file not found: %s", filePath)
		}

		viewerPath, err := findViewerExecutable()
		if err != nil {
			return err
		}

		// grid-viewer handles single-instance internally (PID + socket)
		viewerArgs := []string{filePath}
		if newWindow, _ := cmd.Flags().GetBool("new"); newWindow {
			viewerArgs = []string{"--new", filePath}
		}
		c := exec.Command(viewerPath, viewerArgs...)
		c.Start()
		return nil
	},
}

// MARK: - Terminal Command

// terminalCmd launches or toggles the floating terminal
var terminalCmd = &cobra.Command{
	Use:   "terminal",
	Short: "Toggle the floating scratchpad terminal",
	Long: `Toggle the floating scratchpad terminal (Ghostty running tmux session "grid-scratch").

First invocation launches Ghostty with no decorations, floating above other
windows on all spaces. Subsequent invocations toggle window visibility.
The tmux session persists across toggle cycles.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()
		c := client.NewClient(socketPath, timeout)
		defer c.Close()

		stateDir := filepath.Join(xdg.StateHome(), "thegrid")
		widFile := filepath.Join(stateDir, "terminal-wid")
		pidFile := filepath.Join(stateDir, "terminal-pid")
		frameFile := filepath.Join(stateDir, "terminal-frame")

		savedWID, _ := loadTerminalWID(widFile)
		savedPID, _ := loadTerminalPID(pidFile)

		logTerminal := func(tier int, action string, data map[string]any) {
			if data == nil {
				data = map[string]any{}
			}
			data["tier"] = tier
			data["action"] = action
			data["savedWid"] = savedWID
			data["savedPid"] = savedPID
			jsonlog.Log("term.toggle", jsonlog.WithData(data))
		}

		// Tier 1: Fast path — saved PID alive + saved WID
		if savedPID > 0 && pidAlive(savedPID) && savedWID > 0 {
			// Capture active display BEFORE show (user's current context)
			activeDisplay, displayErr := c.GetActiveDisplay(ctx)

			params := map[string]interface{}{"windowId": fmt.Sprintf("%d", savedWID)}
			result, err := c.CallMethod(ctx, "window.isOrderedIn", params)
			if err == nil {
				isOrderedIn, _ := result["isOrderedIn"].(bool)
				onCurrentSpace := isWindowOnSpace(result, activeDisplay)

				if isOrderedIn && onCurrentSpace {
					// Save window position per-display before hiding
					if frameData, ok := result["frame"].(map[string]interface{}); ok && activeDisplay != nil {
						frames := loadTerminalFrames(frameFile)
						frames[activeDisplay.UUID] = terminalFrame{
							X:      toTermFloat(frameData["x"]),
							Y:      toTermFloat(frameData["y"]),
							Width:  toTermFloat(frameData["width"]),
							Height: toTermFloat(frameData["height"]),
						}
						saveTerminalFrames(frameFile, frames)
					}
					// Visible on current space → hide
					c.CallMethod(ctx, "window.hide", params)
					logTerminal(1, "hide", map[string]any{
						"display": activeDisplay.UUID,
					})
					return nil
				} else {
					// Hidden OR on different space → move + show + position
					if displayErr == nil && activeDisplay != nil {
						frames := loadTerminalFrames(frameFile)
						saved := frames[activeDisplay.UUID]
						positionTerminalOnDisplay(ctx, c, int(savedWID), activeDisplay, false, saved)
					}
					c.CallMethod(ctx, "window.show", params)
					logTerminal(1, "show", map[string]any{"onCurrentSpace": onCurrentSpace})
					return nil
				}
			}
			// RPC failed — WID is stale, clear it but keep PID
			logTerminal(1, "stale", map[string]any{"err": fmt.Sprintf("%v", err)})
			os.Remove(widFile)
			savedWID = 0
		}

		// Tier 2: PID alive but WID stale — find window via server query
		if savedPID > 0 && pidAlive(savedPID) {
			wid, _, found, err := c.FindWindow(ctx, "Ghostty", "grid:scratch")
			if err == nil && found {
				saveTerminalWID(widFile, wid)
				params := map[string]interface{}{"windowId": fmt.Sprintf("%d", wid)}
				c.CallMethod(ctx, "window.hide", params)
				logTerminal(2, "hide", map[string]any{"foundWid": wid})
				return nil
			}
			logTerminal(2, "no_window", nil)
			os.Remove(widFile)
			os.Remove(pidFile)
			os.Remove(frameFile)
		} else if savedPID > 0 {
			logTerminal(2, "pid_dead", nil)
			os.Remove(widFile)
			os.Remove(pidFile)
			os.Remove(frameFile)
		}

		// Tier 3: No saved state — search for orphaned grid-terminal
		if wid, pid, found, err := c.FindWindow(ctx, "Ghostty", "grid:scratch"); err == nil && found {
			saveTerminalWID(widFile, wid)
			saveTerminalPID(pidFile, pid)
			params := map[string]interface{}{"windowId": fmt.Sprintf("%d", wid)}
			c.CallMethod(ctx, "window.hide", params)
			logTerminal(3, "hide", map[string]any{"foundWid": wid, "foundPid": pid})
			return nil
		}

		// Tier 4: Launch fresh Ghostty
		logTerminal(4, "launch", nil)

		// Capture active display before launch (user's current context)
		activeDisplay, _ := c.GetActiveDisplay(ctx)

		tmuxPath := tmux.FindTmux()
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/zsh"
		}
		// Launch tmux via the user's shell to avoid macOS security alert
		// GRID_TERMINAL=scratch env var identifies the scratchpad window
		tmuxCmd := tmuxPath + " new-session -A -s grid-scratch"
		p := exec.Command("open", "-na", "Ghostty.app", "--args",
			"--title=grid:scratch",
			"--window-decoration=none",
			"--quit-after-last-window-closed=true",
			"--env=GRID_TERMINAL=scratch",
			"--command="+shell+" -l -c '"+tmuxCmd+"'")
		if err := p.Run(); err != nil {
			return fmt.Errorf("failed to launch Ghostty: %w", err)
		}

		// Poll with lightweight window.find instead of full dump
		var newWinID uint32
		var newPID int
		for i := 0; i < 50; i++ {
			time.Sleep(100 * time.Millisecond)
			wid, pid, found, err := c.FindWindow(ctx, "Ghostty", "grid:scratch")
			if err == nil && found {
				newWinID = wid
				newPID = pid
				break
			}
		}

		if newWinID == 0 {
			return fmt.Errorf("timed out waiting for Ghostty window to appear")
		}

		// Save state and configure window
		wid := fmt.Sprintf("%d", newWinID)
		saveTerminalWID(widFile, newWinID)
		saveTerminalPID(pidFile, newPID)

		// Position on active display with offset correction
		if activeDisplay != nil {
			positionTerminalOnDisplay(ctx, c, int(newWinID), activeDisplay, true, terminalFrame{})
		}
		c.CallMethod(ctx, "window.setLayer", map[string]interface{}{"windowId": wid, "layer": "above"})
		// No setSticky — terminal follows user to current space on toggle
		logTerminal(4, "ready", map[string]any{"wid": newWinID, "pid": newPID})

		return nil
	},
}

func saveTerminalWID(path string, wid uint32) {
	os.WriteFile(path, []byte(fmt.Sprintf("%d", wid)), 0644)
}

func loadTerminalWID(path string) (uint32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	val, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 32)
	if err != nil {
		return 0, err
	}
	return uint32(val), nil
}

func saveTerminalPID(path string, pid int) {
	os.WriteFile(path, []byte(fmt.Sprintf("%d", pid)), 0644)
}

func loadTerminalPID(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	val, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0, err
	}
	return val, nil
}

// terminalFrame stores the terminal's last known position and size.
type terminalFrame struct {
	X, Y, Width, Height float64
}

// terminalFrames maps display UUID → last known terminal position on that display
type terminalFrames map[string]terminalFrame

func saveTerminalFrames(path string, frames terminalFrames) {
	data, _ := json.Marshal(frames)
	os.WriteFile(path, data, 0644)
}

func loadTerminalFrames(path string) terminalFrames {
	data, err := os.ReadFile(path)
	if err != nil {
		return terminalFrames{}
	}
	var frames terminalFrames
	if json.Unmarshal(data, &frames) != nil {
		return terminalFrames{}
	}
	return frames
}

// toTermFloat converts an interface{} value from JSON map to float64.
func toTermFloat(v interface{}) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	default:
		return 0
	}
}

func pidAlive(pid int) bool {
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	// On Unix, kill(pid, 0) checks if process exists without sending a signal
	return proc.Signal(syscall.Signal(0)) == nil
}


// isWindowOnSpace checks if a window (from isOrderedIn response with spaces array)
// is on the same space as the given display.
func isWindowOnSpace(result map[string]interface{}, display *client.DisplayInfo) bool {
	if display == nil {
		return false
	}
	spacesRaw, ok := result["spaces"].([]interface{})
	if !ok {
		return false
	}
	for _, s := range spacesRaw {
		if fmt.Sprintf("%v", s) == display.CurrentSpaceID {
			return true
		}
	}
	return false
}

// positionTerminalOnDisplay positions the terminal on the given display.
// resize=true: fresh launch, size to 80%×60% and center.
// resize=false: toggle show. If saved frame is on same display, restore exact position.
// If different display (or no saved frame), center using saved dimensions.
func positionTerminalOnDisplay(ctx context.Context, c *client.Client, windowID int, display *client.DisplayInfo, resize bool, saved terminalFrame) {
	logData := map[string]any{"wid": windowID, "displayUUID": display.UUID}

	// Use visibleFrame (excludes menu bar/dock), fall back to frame
	vf := display.VisibleFrame
	if vf.Width == 0 {
		vf = display.Frame
	}
	if vf.Width == 0 {
		logData["result"] = "no_bounds"
		jsonlog.Log("term.position", jsonlog.WithData(logData))
		return
	}

	// Load config for display offset
	var offsetX, offsetY float64
	cfg, err := gridConfig.LoadConfig("")
	if err == nil {
		offset := cfg.GetDisplayOffset(display.UUID, display.Name)
		offsetX = offset.X
		offsetY = offset.Y
	}

	if resize {
		// Fresh launch: 80%×60% centered
		winW := vf.Width * 0.8
		winH := vf.Height * 0.6
		x := vf.X + (vf.Width-winW)/2 + offsetX
		y := vf.Y + (vf.Height-winH)/2 + offsetY
		c.UpdateWindow(ctx, windowID, map[string]interface{}{
			"x": x, "y": y, "width": winW, "height": winH,
		})
		logData["mode"] = "fresh"
		logData["placed"] = map[string]any{"x": x, "y": y, "w": winW, "h": winH}
	} else if saved.Width > 0 && saved.Height > 0 {
		// Saved position for this display: restore exact x,y
		c.UpdateWindow(ctx, windowID, map[string]interface{}{
			"spaceId": display.CurrentSpaceID,
			"x": saved.X, "y": saved.Y,
		})
		logData["mode"] = "restore"
		logData["placed"] = map[string]any{"x": saved.X, "y": saved.Y, "w": saved.Width, "h": saved.Height}
	} else {
		// No saved position for this display: center at 80%×60% without resizing
		winW := vf.Width * 0.8
		winH := vf.Height * 0.6
		x := vf.X + (vf.Width-winW)/2 + offsetX
		y := vf.Y + (vf.Height-winH)/2 + offsetY
		c.UpdateWindow(ctx, windowID, map[string]interface{}{
			"spaceId": display.CurrentSpaceID,
			"x": x, "y": y,
		})
		logData["mode"] = "center"
		logData["placed"] = map[string]any{"x": x, "y": y, "w": winW, "h": winH}
	}

	logData["result"] = "positioned"
	logData["resize"] = resize
	logData["offset"] = map[string]any{"x": offsetX, "y": offsetY}
	jsonlog.Log("term.position", jsonlog.WithData(logData))
}

// humanSize formats bytes into a human-readable string
func humanSize(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func init() {
	// Global flags
	rootCmd.PersistentFlags().StringVar(&socketPath, "socket", client.DefaultSocketPath, "Unix socket path")
	rootCmd.PersistentFlags().DurationVar(&timeout, "timeout", client.DefaultTimeout, "Request timeout")
	rootCmd.PersistentFlags().BoolVar(&jsonOutput, "json", false, "Output in JSON format")
	rootCmd.PersistentFlags().BoolVar(&noColor, "no-color", false, "Disable colored output")

	// Add top-level commands
	rootCmd.AddCommand(pingCmd)
	rootCmd.AddCommand(debugCmd)
	debugCmd.AddCommand(debugBordersCmd)
	rootCmd.AddCommand(infoCmd)
	rootCmd.AddCommand(dumpCmd)
	rootCmd.AddCommand(showCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(windowCmd)
	rootCmd.AddCommand(spaceCmd)
	rootCmd.AddCommand(renderCmd)

	// Add view command
	rootCmd.AddCommand(viewCmd)
	viewCmd.Flags().Bool("new", false, "Open in a new window instead of reusing existing")

	// Add terminal command
	rootCmd.AddCommand(terminalCmd)

	// Add record command and flags
	rootCmd.AddCommand(recordCmd)
	recordCmd.Flags().IntP("duration", "d", 5, "Seconds to record")
	recordCmd.Flags().StringP("output", "o", "", "Output path (auto-generated if empty)")
	recordCmd.Flags().StringP("format", "f", "gif", "Output format: gif, mp4, webm, mov")
	recordCmd.Flags().Int("fps", 0, "Frames per second (0=auto: 10 for gif, 30 for video)")
	recordCmd.Flags().IntP("width", "w", 0, "Max output width (scale, preserve aspect ratio)")
	recordCmd.Flags().StringP("quality", "q", "medium", "Quality preset: low, medium, high")
	recordCmd.Flags().Int("countdown", 3, "Seconds countdown before recording (0 to skip)")
	recordCmd.Flags().Bool("cursor", false, "Include cursor in recording")
	recordCmd.Flags().Bool("open", false, "Open file after recording")
	recordCmd.Flags().Bool("follow", false, "Crop follows focused cell during recording")

	// Add the-grid layout commands
	rootCmd.AddCommand(gridLayoutCmd)
	gridLayoutCmd.AddCommand(layoutListCmd)
	gridLayoutCmd.AddCommand(layoutShowCmd)
	gridLayoutCmd.AddCommand(layoutApplyCmd)
	gridLayoutCmd.AddCommand(layoutCurrentCmd)
	gridLayoutCmd.AddCommand(layoutRefreshCmd)
	gridLayoutCmd.AddCommand(layoutSaveCmd)
	gridLayoutCmd.AddCommand(layoutEditCmd)

	// Add layout command flags
	layoutApplyCmd.Flags().String("space", "", "Space ID to apply layout to")
	layoutCurrentCmd.Flags().String("space", "", "Space ID to check")
	layoutRefreshCmd.Flags().String("display", "", "Only refresh specific display (UUID)")
	layoutEditCmd.Flags().Bool("all", false, "Edit all cells (not just focused cell)")

	// Add the-grid config commands
	rootCmd.AddCommand(gridConfigCmd)
	gridConfigCmd.AddCommand(configSourcesCmd)
	gridConfigCmd.AddCommand(configShowCmd)
	gridConfigCmd.AddCommand(configValidateCmd)
	gridConfigCmd.AddCommand(configInitCmd)

	// Add the-grid state commands
	rootCmd.AddCommand(gridStateCmd)
	gridStateCmd.AddCommand(stateShowCmd)
	gridStateCmd.AddCommand(stateResetCmd)

	// Add event commands (server→CLI callbacks)
	rootCmd.AddCommand(eventCmd)
	eventCmd.AddCommand(eventFocusCmd)

	// Add the-grid pick command
	rootCmd.AddCommand(pickCmd)

	// Add the-grid focus commands
	rootCmd.AddCommand(focusCmd)
	focusCmd.AddCommand(focusLeftCmd)
	focusCmd.AddCommand(focusRightCmd)
	focusCmd.AddCommand(focusUpCmd)
	focusCmd.AddCommand(focusDownCmd)
	focusCmd.AddCommand(focusNextCmd)
	focusCmd.AddCommand(focusPrevCmd)
	focusCmd.AddCommand(focusCellCmd)
	focusCmd.AddCommand(focusInfoCmd)

	// Add focus command flags
	focusLeftCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
	focusRightCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
	focusUpCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")
	focusDownCmd.Flags().Bool("wrap", true, "Wrap around to opposite edge")

	focusLeftCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")
	focusRightCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")
	focusUpCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")
	focusDownCmd.Flags().Bool("extend", false, "Extend focus to adjacent monitors when no cell exists in direction")

	// Add mouse follow flags to all focus commands
	focusLeftCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")
	focusRightCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")
	focusUpCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")
	focusDownCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")
	focusNextCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")
	focusPrevCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")
	focusCellCmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to focused window")

	// Add mouse commands
	rootCmd.AddCommand(mouseCmd)
	mouseCmd.AddCommand(mouseCenterCmd)
	mouseCmd.AddCommand(mouseWarpCmd)

	// Add the-grid resize commands
	rootCmd.AddCommand(gridResizeCmd)
	gridResizeCmd.AddCommand(resizeAdjustCmd)
	gridResizeCmd.AddCommand(resizeResetCmd)
	gridResizeCmd.AddCommand(resizeCellCmd)

	// Add resize command flags
	resizeResetCmd.Flags().Bool("all", false, "Reset all window splits, not just focused cell")
	resizeResetCmd.Flags().Bool("cells", false, "Reset cell/track ratios to layout defaults")

	// Add the-grid cell commands
	rootCmd.AddCommand(cellCmd)
	cellCmd.AddCommand(cellSendCmd)
	cellCmd.AddCommand(cellModeCmd)

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
		cmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to moved window")
	}

	// Add window swap command and subcommands
	windowCmd.AddCommand(windowSwapCmd)
	windowSwapCmd.AddCommand(windowSwapLeftCmd)
	windowSwapCmd.AddCommand(windowSwapRightCmd)
	windowSwapCmd.AddCommand(windowSwapUpCmd)
	windowSwapCmd.AddCommand(windowSwapDownCmd)

	// Add flags for window swap commands
	for _, cmd := range []*cobra.Command{windowSwapLeftCmd, windowSwapRightCmd, windowSwapUpCmd, windowSwapDownCmd} {
		cmd.Flags().BoolP("mouse", "m", false, "Move mouse cursor to swapped window")
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

	// Disable color if requested
	cobra.OnInitialize(func() {
		if noColor {
			color.NoColor = true
		}
	})
}

func main() {
	// Execute command
	err := rootCmd.Execute()

	if err != nil {
		os.Exit(1)
	}
}

// Helper functions

// shouldSkipMutex returns true for commands that don't need serialization.
// These are typically read-only commands or help/completion commands.
func shouldSkipMutex(cmd *cobra.Command) bool {
	cmdPath := cmd.CommandPath()

	// Commands that don't modify state and don't need serialization
	skipPrefixes := []string{
		"thegrid help",
		"thegrid completion",
		"thegrid config show",
		"thegrid config sources",
		"thegrid config validate",
	}

	// Exact matches for simple commands
	skipExact := map[string]bool{
		"thegrid":             true, // Root command (shows help)
		"thegrid ping":        true,
		"thegrid info":        true,
		"thegrid dump":        true,
		"thegrid list":        true,
		"thegrid show":        true,
		"thegrid record":      true,
		"thegrid terminal":    true,
		"thegrid pick":        true,
		"thegrid view":        true,
		"thegrid layout edit": true, // manages its own mutex (release during editor)
	}

	if skipExact[cmdPath] {
		return true
	}

	for _, prefix := range skipPrefixes {
		if strings.HasPrefix(cmdPath, prefix) {
			return true
		}
	}

	// Also skip if it's a help invocation (has --help flag)
	if cmd.Flags().Changed("help") {
		return true
	}

	return false
}

func printJSON(data interface{}) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(data)
}

func printYAML(data interface{}) error {
	enc := yaml.NewEncoder(os.Stdout)
	enc.SetIndent(2)
	defer enc.Close()
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
