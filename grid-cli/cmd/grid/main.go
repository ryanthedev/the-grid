package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
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

		// Start command span
		currentSpan = jsonlog.StartSpan("cmd", jsonlog.WithData(map[string]any{
			"cmd":  cmd.CommandPath(),
			"args": argsMap,
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

// pickCmd is the parent command for pick subcommands
var pickCmd = &cobra.Command{
	Use:   "pick",
	Short: "Interactive picker commands",
	Long:  `Commands for displaying interactive picker interfaces.`,
}

// pickWindowCmd launches an interactive window picker
var pickWindowCmd = &cobra.Command{
	Use:   "window",
	Short: "Pick a window interactively",
	Long:  `Launches an interactive picker to select a window from a list.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		return runPickWindow()
	},
}

// PickerItem represents an item for the grid-picker UI
type PickerItem struct {
	ID         string            `json:"id"`
	Title      string            `json:"title"`
	Subtitle   string            `json:"subtitle,omitempty"`
	Preview    string            `json:"preview,omitempty"`
	Icon       string            `json:"icon,omitempty"`
	Searchable []string          `json:"searchable"`
	Metadata   map[string]string `json:"metadata,omitempty"`
}

// PickerResult represents the outcome of a picker interaction
type PickerResult struct {
	Cancelled bool        `json:"cancelled"`
	Selected  *PickerItem `json:"selected,omitempty"`
}

// tmuxEnrichment holds tmux session info for a terminal window
type tmuxEnrichment struct {
	sessionName string
	windowName  string
	paneCommand string
}

// PickerContext holds additional data needed for stable ID generation
type PickerContext struct {
	TmuxInfo  map[int]*tmuxEnrichment
	BundleIDs map[int]string
	Titles    map[int]string
	PIDs      map[int]int
}

// findPickerExecutable locates the grid-picker binary by checking standard locations
func findPickerExecutable() (string, error) {
	// Build list of paths to check in order of preference
	var searchPaths []string
	var searchedLocations []string

	// 1. XDG state home: ~/.local/state/thegrid/grid-picker
	stateDir := filepath.Join(xdg.StateHome(), "thegrid")
	statePath := filepath.Join(stateDir, "grid-picker")
	searchPaths = append(searchPaths, statePath)
	searchedLocations = append(searchedLocations, statePath)

	// 2. Same directory as current executable
	if execPath, err := os.Executable(); err == nil {
		execDir := filepath.Dir(execPath)
		execDirPath := filepath.Join(execDir, "grid-picker")
		searchPaths = append(searchPaths, execDirPath)
		searchedLocations = append(searchedLocations, execDirPath)
	}

	// 3. System PATH lookup
	if pathExec, err := exec.LookPath("grid-picker"); err == nil {
		searchPaths = append(searchPaths, pathExec)
	}
	searchedLocations = append(searchedLocations, "system PATH")

	// Check each path for existence and executability
	for _, path := range searchPaths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		// Check if file is executable (has any execute bit set)
		if info.Mode()&0111 != 0 {
			return path, nil
		}
	}

	// Build error message listing all searched locations
	return "", fmt.Errorf("grid-picker not found in:\n  - %s", strings.Join(searchedLocations, "\n  - "))
}

// launchPicker spawns the picker executable with items and returns the selection result
func launchPicker(items []PickerItem) (*PickerResult, error) {
	// Find the picker executable
	pickerPath, err := findPickerExecutable()
	if err != nil {
		return nil, err
	}

	// Create command with timeout context (5 min generous limit for interactive use)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, pickerPath)

	// Set up pipes for stdin, stdout, stderr
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to create stdin pipe: %w", err)
	}

	// Start the command
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start picker: %w", err)
	}

	// Encode items as JSON and write to stdin
	encoder := json.NewEncoder(stdin)
	if err := encoder.Encode(items); err != nil {
		stdin.Close()
		cmd.Wait()
		return nil, fmt.Errorf("failed to write items to picker: %w", err)
	}
	stdin.Close()

	// Wait for command to complete
	waitErr := cmd.Wait()

	// Check exit code
	if waitErr != nil {
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			// Exit code 1 means user cancelled (not an error)
			if exitErr.ExitCode() == 1 {
				return &PickerResult{Cancelled: true, Selected: nil}, nil
			}
			// Other non-zero exit codes are errors
			return nil, fmt.Errorf("picker failed (exit %d): %s", exitErr.ExitCode(), stderr.String())
		}
		return nil, fmt.Errorf("picker failed: %w", waitErr)
	}

	// Parse stdout as picker result JSON (wrapper with cancelled + selected fields)
	var result PickerResult
	if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
		return nil, fmt.Errorf("failed to parse picker output: %w", err)
	}

	return &result, nil
}

// getAllWindows fetches all windows from the server via dump RPC
func getAllWindows(ctx context.Context, c *client.Client) ([]*models.Window, *models.State, error) {
	result, err := c.Dump(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to dump state: %w", err)
	}

	state, err := models.ParseState(result)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to parse state: %w", err)
	}

	windows := filterWindows(state.GetWindows())
	return windows, state, nil
}

// windowsToPickerItems transforms windows into PickerItem format for grid-picker
// Also returns PickerContext with data needed for stable ID generation
func windowsToPickerItems(windows []*models.Window, state *models.State) ([]PickerItem, *PickerContext) {
	items := make([]PickerItem, 0, len(windows))
	pctx := &PickerContext{
		TmuxInfo:  make(map[int]*tmuxEnrichment),
		BundleIDs: make(map[int]string),
		Titles:    make(map[int]string),
		PIDs:      make(map[int]int),
	}

	// Get tmux clients and cache for enriching terminal windows
	tmuxClients, _ := tmux.GetClients()
	tmuxCache, _ := tmux.LoadCache()

	// Refresh process tree once (single ps call instead of many pgrep calls)
	process.RefreshProcessTree()

	// Track which PIDs have already been enriched (multiple windows can share same PID)
	enrichedPIDs := make(map[int]bool)

	for _, w := range windows {
		// Store PID for stable ID generation
		pctx.PIDs[w.ID] = w.PID

		// Get title with fallback
		title := "Untitled"
		if w.Title != nil && *w.Title != "" {
			title = *w.Title
		}
		// Store original title for stable ID
		pctx.Titles[w.ID] = title

		// Get app name with fallback
		appName := "Unknown"
		if w.AppName != nil && *w.AppName != "" {
			appName = *w.AppName
		}

		// Get bundle identifier from application
		bundleID := ""
		if app := state.FindApplicationByPID(w.PID); app != nil {
			bundleID = app.BundleIdentifier
		}
		pctx.BundleIDs[w.ID] = bundleID

		// Try to enrich terminal windows with tmux session info
		// Only enrich first window per PID to avoid duplicates (e.g., multiple Ghostty tabs)
		if tmux.IsTerminalApp(bundleID) && len(tmuxClients) > 0 && !enrichedPIDs[w.PID] {
			if info := enrichWithTmux(w, tmuxCache, tmuxClients); info != nil {
				title = info.SessionName
				pctx.TmuxInfo[w.ID] = &tmuxEnrichment{
					sessionName: info.SessionName,
					windowName:  info.WindowName,
					paneCommand: info.PaneCommand,
				}
				enrichedPIDs[w.PID] = true
			}
		}

		// Build searchable strings
		searchable := []string{title, appName}
		if bundleID != "" {
			searchable = append(searchable, bundleID)
		}

		// Build icon string (bundle: prefix for app icons)
		icon := ""
		if bundleID != "" {
			icon = "bundle:" + bundleID
		}

		// Build subtitle and preview
		subtitle := appName
		preview := ""
		if enrichment, ok := pctx.TmuxInfo[w.ID]; ok {
			subtitle = fmt.Sprintf("%s:%s", enrichment.sessionName, enrichment.windowName)
			preview = enrichment.paneCommand
			// Add tmux info to searchable
			searchable = append(searchable, enrichment.sessionName, enrichment.windowName)
		}

		item := PickerItem{
			ID:         strconv.Itoa(w.ID),
			Title:      title,
			Subtitle:   subtitle,
			Preview:    preview,
			Icon:       icon,
			Searchable: searchable,
			Metadata:   map[string]string{"wid": strconv.Itoa(w.ID)},
		}
		items = append(items, item)
	}

	// Prune and save cache
	if len(tmuxClients) > 0 {
		validClientPIDs := make(map[int]bool)
		for pid := range tmuxClients {
			validClientPIDs[pid] = true
		}
		tmuxCache.Prune(validClientPIDs)
		tmuxCache.Save()
	}

	return items, pctx
}

// enrichWithTmux attempts to find tmux session info for a terminal window.
// Returns the TmuxClientInfo if found, nil otherwise.
func enrichWithTmux(w *models.Window, cache *tmux.Cache, clients map[int]tmux.TmuxClientInfo) *tmux.TmuxClientInfo {
	// Try cache first
	if clientPID, found := cache.Lookup(w.PID); found {
		if info, ok := clients[clientPID]; ok {
			return &info
		}
	}

	// Cache miss - search process tree (depth 4 to handle login->shell->bash->tmux)
	descendants, _ := process.GetDescendantPIDs(w.PID, 4)
	for _, pid := range descendants {
		if info, ok := clients[pid]; ok {
			cache.Store(w.PID, pid)
			return &info
		}
	}

	return nil
}

// normalizeTitle converts a title to a stable, URL-safe form
// lowercase, keep alphanumeric + hyphens, truncate to 30 chars
func normalizeTitle(title string) string {
	// Convert to lowercase
	title = strings.ToLower(title)
	// Replace non-alphanumeric with hyphens, collapse multiple hyphens
	re := regexp.MustCompile(`[^a-z0-9]+`)
	title = re.ReplaceAllString(title, "-")
	// Trim leading/trailing hyphens
	title = strings.Trim(title, "-")
	// Truncate to 30 chars
	if len(title) > 30 {
		title = title[:30]
	}
	// Trim trailing hyphen after truncation
	title = strings.TrimSuffix(title, "-")
	return title
}

// hash4 returns the first 4 hex chars of SHA256(s) for collision resistance
func hash4(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])[:4]
}

// stableWindowID generates a stable identifier for a window that persists across restarts.
// Tmux windows: tmux:{session}:{window}
// Non-tmux: {bundleID}:{normalized_title}:{hash4}
func stableWindowID(wid int, tmuxInfo *tmuxEnrichment, bundleID, title string, pid int) string {
	// Tmux windows
	if tmuxInfo != nil {
		session := tmuxInfo.sessionName
		window := tmuxInfo.windowName
		if session != "" && window != "" {
			return fmt.Sprintf("tmux:%s:%s", session, window)
		}
		// Fallback for empty session/window
		return fmt.Sprintf("tmux:unknown:%d", pid)
	}

	// Non-tmux with bundleID
	if bundleID != "" {
		if title != "" && title != "Untitled" {
			normalized := normalizeTitle(title)
			if normalized != "" {
				return fmt.Sprintf("%s:%s:%s", bundleID, normalized, hash4(title))
			}
		}
		// Empty title fallback
		return fmt.Sprintf("%s:untitled:%d", bundleID, wid)
	}

	// Ultimate fallback
	return fmt.Sprintf("unknown:%d", wid)
}

// sortItemsByHistory sorts picker items with previous window first,
// then by frequency descending, then alphabetically by title
func sortItemsByHistory(items []PickerItem, stableIDs map[int]string, history *gridState.PickerHistory) {
	sort.SliceStable(items, func(i, j int) bool {
		widI, _ := strconv.Atoi(items[i].Metadata["wid"])
		widJ, _ := strconv.Atoi(items[j].Metadata["wid"])
		idI := stableIDs[widI]
		idJ := stableIDs[widJ]

		// Previous window first
		prevI := history.IsPrevious(idI)
		prevJ := history.IsPrevious(idJ)
		if prevI != prevJ {
			return prevI
		}

		// Then by frequency descending
		freqI := history.GetFrequency(idI)
		freqJ := history.GetFrequency(idJ)
		if freqI != freqJ {
			return freqI > freqJ
		}

		// Finally alphabetically by title
		return items[i].Title < items[j].Title
	})
}

// runPickWindow launches the interactive window picker
func runPickWindow() error {
	ctx := context.Background()
	c := client.NewClient(socketPath, timeout)
	defer c.Close()

	jsonlog.Log("pick.start")

	// Get windows from server
	windows, serverState, err := getAllWindows(ctx, c)
	if err != nil {
		return err
	}

	if len(windows) == 0 {
		return fmt.Errorf("no windows found")
	}

	// Load runtime state to get cell assignments
	runtimeState, err := gridState.LoadState()
	if err != nil {
		return fmt.Errorf("failed to load state: %w", err)
	}

	// Load config for border sync
	cfg, err := gridConfig.LoadConfig("")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Collect all window IDs assigned to cells across ALL current spaces (one per display)
	// Also track which display each window is on for border sync
	assignedWindowIDs := make(map[uint32]bool)
	windowToDisplay := make(map[uint32]string)
	for _, display := range serverState.Displays {
		spaceID := display.GetCurrentSpaceIDString()
		if spaceID == "" {
			continue
		}
		spaceState := runtimeState.GetSpaceReadOnly(spaceID)
		if spaceState == nil {
			continue
		}
		for _, cell := range spaceState.Cells {
			for _, wid := range cell.Windows {
				assignedWindowIDs[wid] = true
				windowToDisplay[wid] = display.UUID
			}
		}
	}

	if len(assignedWindowIDs) == 0 {
		return fmt.Errorf("no windows assigned to cells (run a layout first)")
	}

	// Filter windows to only those assigned to cells
	filteredWindows := make([]*models.Window, 0, len(windows))
	for _, w := range windows {
		if assignedWindowIDs[uint32(w.ID)] {
			filteredWindows = append(filteredWindows, w)
		}
	}

	if len(filteredWindows) == 0 {
		return fmt.Errorf("no windows assigned to cells (run a layout first)")
	}

	// Transform to picker items and get context for stable ID generation
	items, pctx := windowsToPickerItems(filteredWindows, serverState)

	// Generate stable IDs for each window
	stableIDs := make(map[int]string)
	for _, item := range items {
		wid, _ := strconv.Atoi(item.Metadata["wid"])
		stableIDs[wid] = stableWindowID(
			wid,
			pctx.TmuxInfo[wid],
			pctx.BundleIDs[wid],
			pctx.Titles[wid],
			pctx.PIDs[wid],
		)
	}

	// Load picker history for sorting
	history, err := gridState.LoadPickerHistory()
	if err != nil {
		jsonlog.Log("pick.history.load_err", jsonlog.WithMsg(err.Error()))
		history = gridState.NewPickerHistory()
	}

	// Sort items by history (previous first, then by frequency)
	sortItemsByHistory(items, stableIDs, history)

	// Launch picker with items
	result, err := launchPicker(items)
	if err != nil {
		return err
	}

	// Handle cancellation (silent exit)
	if result.Cancelled {
		jsonlog.Log("pick.cancel")
		return nil
	}

	// Extract window ID from metadata
	if result.Selected == nil {
		return nil
	}

	widStr, ok := result.Selected.Metadata["wid"]
	if !ok || widStr == "" {
		return fmt.Errorf("selected item missing window ID")
	}

	widInt, err := strconv.ParseUint(widStr, 10, 32)
	if err != nil {
		return fmt.Errorf("invalid window ID %q: %w", widStr, err)
	}
	windowID := uint32(widInt)

	// Record selection in history
	if sid, ok := stableIDs[int(windowID)]; ok {
		history.RecordSelection(sid)
		if err := history.Save(); err != nil {
			jsonlog.Log("pick.history.save_err", jsonlog.WithMsg(err.Error()))
		}
	}

	jsonlog.Log("pick.select", jsonlog.WithData(map[string]any{"wid": windowID}))

	// Focus the selected window
	if err := gridFocus.FocusWindow(ctx, c, windowID); err != nil {
		// Check if window no longer exists
		if strings.Contains(err.Error(), "invalid") || strings.Contains(err.Error(), "not found") {
			return fmt.Errorf("window no longer exists")
		}
		return fmt.Errorf("focus failed: %w", err)
	}

	// Sync border focus so the active border updates to the newly focused window
	if displayUUID := windowToDisplay[windowID]; displayUUID != "" {
		gridReconcile.SyncBorderFocus(ctx, c, displayUUID, windowID, cfg)
	}

	// Warp mouse to window (non-fatal if it fails since focus succeeded)
	if err := gridMouse.WarpToWindow(ctx, c, windowID); err != nil {
		jsonlog.Log("pick.warp_warn", jsonlog.WithMsg("mouse warp failed after focus"), jsonlog.WithData(map[string]any{
			"wid": windowID,
			"err": err.Error(),
		}))
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
	rootCmd.AddCommand(renderCmd)

	// Add the-grid layout commands
	rootCmd.AddCommand(gridLayoutCmd)
	gridLayoutCmd.AddCommand(layoutListCmd)
	gridLayoutCmd.AddCommand(layoutShowCmd)
	gridLayoutCmd.AddCommand(layoutApplyCmd)
	gridLayoutCmd.AddCommand(layoutCurrentCmd)
	gridLayoutCmd.AddCommand(layoutRefreshCmd)

	// Add layout command flags
	layoutApplyCmd.Flags().String("space", "", "Space ID to apply layout to")
	layoutCurrentCmd.Flags().String("space", "", "Space ID to check")
	layoutRefreshCmd.Flags().String("display", "", "Only refresh specific display (UUID)")

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

	// Add the-grid pick commands
	rootCmd.AddCommand(pickCmd)
	pickCmd.AddCommand(pickWindowCmd)

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
		"thegrid":      true, // Root command (shows help)
		"thegrid ping": true,
		"thegrid info": true,
		"thegrid dump": true,
		"thegrid list": true,
		"thegrid show": true,
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
