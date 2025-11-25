# Phase 5: CLI Commands Integration

## Overview

Implement the CLI commands that expose layout functionality to users. This phase integrates all other modules into user-facing commands.

**Location**: `grid-cli/cmd/grid/` (extend main.go or create new command files)

**Dependencies**: Phase 1, 2, 3, 4, 6, 7 (all other phases)

**Note**: This phase integrates all modules. Can start with stubs while other phases complete.

---

## Scope

1. Layout management commands (list, show, apply, cycle)
2. Config commands (show, validate, init)
3. State commands (show, reset)
4. Focus commands (left/right/up/down, next/prev, cell)
5. Resize commands (grow, shrink, reset)

---

## Command Structure

```
grid layout list                    # List available layouts
grid layout show <id>               # Show layout details
grid layout apply <id> [--space]    # Apply layout to current/specified space
grid layout cycle [--space]         # Cycle to next layout
grid layout current [--space]       # Show current layout

grid config show                    # Show current config
grid config validate [path]         # Validate config file
grid config init                    # Create default config

grid state show                     # Show runtime state
grid state reset                    # Clear runtime state

grid focus left|right|up|down       # Move focus to adjacent cell
grid focus next|prev                # Cycle focus within cell
grid focus cell <id|number>         # Jump to specific cell

grid resize grow|shrink [amount]    # Resize focused window
grid resize reset                   # Reset to equal splits
```

---

## Implementation

### Layout Commands

Add to `cmd/grid/main.go` or create `cmd/grid/layout.go`:

```go
package main

import (
    "context"
    "fmt"
    "os"

    "github.com/spf13/cobra"
    "github.com/yourusername/grid-cli/internal/client"
    "github.com/yourusername/grid-cli/internal/config"
    "github.com/yourusername/grid-cli/internal/layout"
    "github.com/yourusername/grid-cli/internal/state"
)

// layout command group
var layoutCmd = &cobra.Command{
    Use:   "layout",
    Short: "Manage window layouts",
    Long:  "Commands for listing, applying, and cycling window layouts",
}

// layout list
var layoutListCmd = &cobra.Command{
    Use:   "list",
    Short: "List available layouts",
    RunE: func(cmd *cobra.Command, args []string) error {
        cfg, err := config.LoadConfig("")
        if err != nil {
            return fmt.Errorf("failed to load config: %w", err)
        }

        if jsonOutput {
            return printJSON(cfg.Layouts)
        }

        // Table output
        fmt.Println("Available Layouts:")
        fmt.Println()
        for _, l := range cfg.Layouts {
            fmt.Printf("  %s\n", l.ID)
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

// layout show
var layoutShowCmd = &cobra.Command{
    Use:   "show <layout-id>",
    Short: "Show layout details",
    Args:  cobra.ExactArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        layoutID := args[0]

        cfg, err := config.LoadConfig("")
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

        fmt.Printf("Layout: %s\n", l.ID)
        fmt.Printf("Name: %s\n", l.Name)
        if l.Description != "" {
            fmt.Printf("Description: %s\n", l.Description)
        }
        fmt.Println()

        fmt.Println("Grid:")
        fmt.Printf("  Columns: %v\n", formatTrackSizes(l.Columns))
        fmt.Printf("  Rows: %v\n", formatTrackSizes(l.Rows))
        fmt.Println()

        fmt.Println("Cells:")
        for _, cell := range l.Cells {
            fmt.Printf("  %s: col %d-%d, row %d-%d\n",
                cell.ID, cell.ColumnStart, cell.ColumnEnd, cell.RowStart, cell.RowEnd)
        }

        return nil
    },
}

// layout apply
var layoutApplyCmd = &cobra.Command{
    Use:   "apply <layout-id>",
    Short: "Apply a layout to the current space",
    Args:  cobra.ExactArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        layoutID := args[0]
        spaceID, _ := cmd.Flags().GetString("space")

        cfg, err := config.LoadConfig("")
        if err != nil {
            return fmt.Errorf("failed to load config: %w", err)
        }

        runtimeState, err := state.LoadState()
        if err != nil {
            return fmt.Errorf("failed to load state: %w", err)
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        opts := layout.DefaultApplyOptions()
        opts.SpaceID = spaceID
        opts.Gap = float64(cfg.Settings.CellPadding)

        ctx := context.Background()
        if err := layout.ApplyLayout(ctx, c, cfg, runtimeState, layoutID, opts); err != nil {
            return fmt.Errorf("failed to apply layout: %w", err)
        }

        fmt.Printf("Applied layout: %s\n", layoutID)
        return nil
    },
}

// layout cycle
var layoutCycleCmd = &cobra.Command{
    Use:   "cycle",
    Short: "Cycle to the next layout",
    RunE: func(cmd *cobra.Command, args []string) error {
        spaceID, _ := cmd.Flags().GetString("space")

        cfg, err := config.LoadConfig("")
        if err != nil {
            return fmt.Errorf("failed to load config: %w", err)
        }

        runtimeState, err := state.LoadState()
        if err != nil {
            return fmt.Errorf("failed to load state: %w", err)
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        opts := layout.DefaultApplyOptions()
        opts.Gap = float64(cfg.Settings.CellPadding)

        ctx := context.Background()
        newLayoutID, err := layout.CycleLayout(ctx, c, cfg, runtimeState, spaceID, opts)
        if err != nil {
            return fmt.Errorf("failed to cycle layout: %w", err)
        }

        fmt.Printf("Switched to layout: %s\n", newLayoutID)
        return nil
    },
}

// layout current
var layoutCurrentCmd = &cobra.Command{
    Use:   "current",
    Short: "Show current layout for space",
    RunE: func(cmd *cobra.Command, args []string) error {
        spaceID, _ := cmd.Flags().GetString("space")

        runtimeState, err := state.LoadState()
        if err != nil {
            return fmt.Errorf("failed to load state: %w", err)
        }

        // If no space specified, get current from server
        if spaceID == "" {
            c := client.NewClient(socketPath, timeout)
            defer c.Close()
            // ... get current space ID from server
            spaceID = "1" // fallback
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

func init() {
    // Add subcommands
    layoutCmd.AddCommand(layoutListCmd)
    layoutCmd.AddCommand(layoutShowCmd)
    layoutCmd.AddCommand(layoutApplyCmd)
    layoutCmd.AddCommand(layoutCycleCmd)
    layoutCmd.AddCommand(layoutCurrentCmd)

    // Add flags
    layoutApplyCmd.Flags().String("space", "", "Space ID to apply layout to")
    layoutCycleCmd.Flags().String("space", "", "Space ID to cycle layout for")
    layoutCurrentCmd.Flags().String("space", "", "Space ID to check")

    // Add to root command
    rootCmd.AddCommand(layoutCmd)
}

// Helper functions
func formatTrackSizes(tracks []types.TrackSize) string {
    var parts []string
    for _, t := range tracks {
        parts = append(parts, config.FormatTrackSize(t))
    }
    return fmt.Sprintf("[%s]", strings.Join(parts, ", "))
}
```

### Config Commands

```go
// config command group
var configCmd = &cobra.Command{
    Use:   "config",
    Short: "Manage configuration",
}

// config show
var configShowCmd = &cobra.Command{
    Use:   "show",
    Short: "Show current configuration",
    RunE: func(cmd *cobra.Command, args []string) error {
        cfg, err := config.LoadConfig("")
        if err != nil {
            return fmt.Errorf("failed to load config: %w", err)
        }

        return printJSON(cfg)
    },
}

// config validate
var configValidateCmd = &cobra.Command{
    Use:   "validate [path]",
    Short: "Validate configuration file",
    Args:  cobra.MaximumNArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        path := ""
        if len(args) > 0 {
            path = args[0]
        }

        cfg, err := config.LoadConfig(path)
        if err != nil {
            return fmt.Errorf("validation failed: %w", err)
        }

        // Additional validation
        if err := cfg.Validate(); err != nil {
            return fmt.Errorf("validation failed: %w", err)
        }

        fmt.Println("Configuration is valid")
        fmt.Printf("  Layouts: %d\n", len(cfg.Layouts))
        fmt.Printf("  Spaces: %d\n", len(cfg.Spaces))
        fmt.Printf("  App Rules: %d\n", len(cfg.AppRules))

        return nil
    },
}

// config init
var configInitCmd = &cobra.Command{
    Use:   "init",
    Short: "Create default configuration file",
    RunE: func(cmd *cobra.Command, args []string) error {
        path := config.GetConfigPath()

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

        fmt.Printf("Created default config at: %s\n", path)
        return nil
    },
}

func init() {
    configCmd.AddCommand(configShowCmd)
    configCmd.AddCommand(configValidateCmd)
    configCmd.AddCommand(configInitCmd)
    rootCmd.AddCommand(configCmd)
}
```

### State Commands

```go
// state command group
var stateCmd = &cobra.Command{
    Use:   "state",
    Short: "Manage runtime state",
}

// state show
var stateShowCmd = &cobra.Command{
    Use:   "show",
    Short: "Show runtime state",
    RunE: func(cmd *cobra.Command, args []string) error {
        runtimeState, err := state.LoadState()
        if err != nil {
            return fmt.Errorf("failed to load state: %w", err)
        }

        if jsonOutput {
            return printJSON(runtimeState)
        }

        summary := runtimeState.Summary()
        fmt.Printf("State Version: %v\n", summary["version"])
        fmt.Printf("Last Updated: %v\n", summary["lastUpdated"])
        fmt.Printf("Spaces: %v\n", summary["spaceCount"])
        fmt.Println()

        for spaceID, spaceInfo := range summary["spaces"].(map[string]interface{}) {
            info := spaceInfo.(map[string]interface{})
            fmt.Printf("Space %s:\n", spaceID)
            fmt.Printf("  Current Layout: %v\n", info["currentLayout"])
            fmt.Printf("  Cells: %v\n", info["cellCount"])
            fmt.Printf("  Windows: %v\n", info["windowCount"])
            fmt.Printf("  Focused Cell: %v\n", info["focusedCell"])
            fmt.Println()
        }

        return nil
    },
}

// state reset
var stateResetCmd = &cobra.Command{
    Use:   "reset",
    Short: "Clear all runtime state",
    RunE: func(cmd *cobra.Command, args []string) error {
        runtimeState, err := state.LoadState()
        if err != nil {
            return fmt.Errorf("failed to load state: %w", err)
        }

        if err := runtimeState.Reset(); err != nil {
            return fmt.Errorf("failed to reset state: %w", err)
        }

        fmt.Println("State has been reset")
        return nil
    },
}

func init() {
    stateCmd.AddCommand(stateShowCmd)
    stateCmd.AddCommand(stateResetCmd)
    rootCmd.AddCommand(stateCmd)
}
```

### Focus Commands

```go
// focus command group
var focusCmd = &cobra.Command{
    Use:   "focus",
    Short: "Manage window focus",
}

// focus direction (left/right/up/down)
var focusDirectionCmd = &cobra.Command{
    Use:   "left|right|up|down",
    Short: "Move focus to adjacent cell",
    Args:  cobra.ExactArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        direction, ok := types.ParseDirection(args[0])
        if !ok {
            return fmt.Errorf("invalid direction: %s (use left, right, up, or down)", args[0])
        }

        cfg, err := config.LoadConfig("")
        if err != nil {
            return err
        }

        runtimeState, err := state.LoadState()
        if err != nil {
            return err
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        ctx := context.Background()
        if err := focus.MoveFocus(ctx, c, cfg, runtimeState, direction); err != nil {
            return fmt.Errorf("failed to move focus: %w", err)
        }

        return nil
    },
}

// focus next/prev
var focusCycleCmd = &cobra.Command{
    Use:   "next|prev",
    Short: "Cycle focus within current cell",
    Args:  cobra.ExactArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        forward := args[0] == "next"

        runtimeState, err := state.LoadState()
        if err != nil {
            return err
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        ctx := context.Background()
        if err := focus.CycleFocusInCell(ctx, c, runtimeState, forward); err != nil {
            return fmt.Errorf("failed to cycle focus: %w", err)
        }

        return nil
    },
}

// focus cell
var focusCellCmd = &cobra.Command{
    Use:   "cell <id|number>",
    Short: "Jump focus to specific cell",
    Args:  cobra.ExactArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        cellID := args[0]

        runtimeState, err := state.LoadState()
        if err != nil {
            return err
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        ctx := context.Background()
        if err := focus.FocusCell(ctx, c, runtimeState, cellID); err != nil {
            return fmt.Errorf("failed to focus cell: %w", err)
        }

        return nil
    },
}

func init() {
    focusCmd.AddCommand(focusDirectionCmd)
    focusCmd.AddCommand(focusCycleCmd)
    focusCmd.AddCommand(focusCellCmd)
    rootCmd.AddCommand(focusCmd)
}
```

### Resize Commands

```go
// resize command group
var resizeCmd = &cobra.Command{
    Use:   "resize",
    Short: "Resize windows",
}

// resize grow/shrink
var resizeAdjustCmd = &cobra.Command{
    Use:   "grow|shrink [amount]",
    Short: "Grow or shrink focused window",
    Args:  cobra.RangeArgs(1, 2),
    RunE: func(cmd *cobra.Command, args []string) error {
        grow := args[0] == "grow"
        amount := 0.1 // default 10%
        if len(args) > 1 {
            fmt.Sscanf(args[1], "%f", &amount)
        }

        if !grow {
            amount = -amount
        }

        cfg, err := config.LoadConfig("")
        if err != nil {
            return err
        }

        runtimeState, err := state.LoadState()
        if err != nil {
            return err
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        ctx := context.Background()
        if err := layout.AdjustSplit(ctx, c, cfg, runtimeState, amount); err != nil {
            return fmt.Errorf("failed to resize: %w", err)
        }

        return nil
    },
}

// resize reset
var resizeResetCmd = &cobra.Command{
    Use:   "reset",
    Short: "Reset splits to equal",
    RunE: func(cmd *cobra.Command, args []string) error {
        cfg, err := config.LoadConfig("")
        if err != nil {
            return err
        }

        runtimeState, err := state.LoadState()
        if err != nil {
            return err
        }

        c := client.NewClient(socketPath, timeout)
        defer c.Close()

        ctx := context.Background()
        if err := layout.ResetSplits(ctx, c, cfg, runtimeState); err != nil {
            return fmt.Errorf("failed to reset splits: %w", err)
        }

        fmt.Println("Splits reset to equal")
        return nil
    },
}

func init() {
    resizeCmd.AddCommand(resizeAdjustCmd)
    resizeCmd.AddCommand(resizeResetCmd)
    rootCmd.AddCommand(resizeCmd)
}
```

---

## Script Examples

Since hotkey registration is deferred, users can create shell scripts:

### apply-layout.sh
```bash
#!/bin/bash
# Apply a layout by name
grid layout apply "$1"
```

### cycle-layout.sh
```bash
#!/bin/bash
# Cycle to next layout
grid layout cycle
```

### focus-left.sh
```bash
#!/bin/bash
# Move focus left
grid focus left
```

These can be bound to system hotkeys using tools like Karabiner, skhd, or Hammerspoon.

---

## Acceptance Criteria

1. All commands work without errors when called correctly
2. Commands provide helpful error messages for invalid input
3. JSON output mode works for all commands
4. Commands properly load config and state
5. State is persisted after layout changes
6. Commands follow existing CLI patterns in main.go

---

## Test Scenarios

```bash
# Layout commands
grid layout list
grid layout show two-column
grid layout apply two-column
grid layout cycle
grid layout current

# Config commands
grid config show
grid config validate
grid config init  # (only if config doesn't exist)

# State commands
grid state show
grid state reset

# Focus commands
grid focus left
grid focus right
grid focus next
grid focus prev
grid focus cell main

# Resize commands
grid resize grow
grid resize shrink 0.05
grid resize reset

# With JSON output
grid layout list --json
grid state show --json
```

---

## Notes for Implementing Agent

1. Follow existing patterns in `cmd/grid/main.go` for command structure
2. Reuse existing global variables (socketPath, timeout, jsonOutput)
3. Use existing `printJSON` helper for JSON output
4. Commands should be idempotent where possible
5. Error messages should be user-friendly and actionable
6. Consider adding `--verbose` flag for debugging
7. Test with actual server connection
8. Commands can be split into separate files (layout.go, config.go, etc.) or kept in main.go
