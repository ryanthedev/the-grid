package config

import "github.com/yourusername/grid-cli/internal/types"

// Config is the root configuration structure
type Config struct {
	Settings Settings               `yaml:"settings" json:"settings"`
	Layouts  []LayoutConfig         `yaml:"layouts" json:"layouts"`
	Spaces   map[string]SpaceConfig `yaml:"spaces" json:"spaces"`
	AppRules []AppRule              `yaml:"appRules" json:"appRules"`
	Borders  *BorderConfig          `yaml:"borders,omitempty" json:"borders,omitempty"`
}

// Settings contains global application settings
type Settings struct {
	DefaultStackMode  types.StackMode  `yaml:"defaultStackMode" json:"defaultStackMode"`
	AnimationDuration float64          `yaml:"animationDuration" json:"animationDuration"`
	BaseSpacing       float64          `yaml:"baseSpacing" json:"baseSpacing"`                         // Base unit for "Nx" padding syntax
	Padding           interface{}      `yaml:"padding,omitempty" json:"padding,omitempty"`             // Global default padding (supports shorthand)
	WindowSpacing     interface{}      `yaml:"windowSpacing,omitempty" json:"windowSpacing,omitempty"` // Gap between stacked windows (supports shorthand)
	FocusFollowsMouse bool             `yaml:"focusFollowsMouse" json:"focusFollowsMouse"`
	Resize            ResizeSettings   `yaml:"resize,omitempty" json:"resize,omitempty"`
	WindowExclusion   WindowExclusion  `yaml:"windowExclusion,omitempty" json:"windowExclusion,omitempty"`
}

// ResizeSettings configures CLI resize behavior
type ResizeSettings struct {
	MinRatio float64 `yaml:"minRatio,omitempty" json:"minRatio,omitempty"` // Minimum cell ratio (default 0.1)
	MaxRatio float64 `yaml:"maxRatio,omitempty" json:"maxRatio,omitempty"` // Maximum cell ratio (default 0.9)
}

// WindowExclusion configures which windows to exclude from cell assignment.
// Windows matching ANY of these criteria are excluded from tiling.
type WindowExclusion struct {
	Roles    []string `yaml:"roles,omitempty" json:"roles,omitempty"`       // AX roles to exclude (e.g., "AXHelpTag")
	Subroles []string `yaml:"subroles,omitempty" json:"subroles,omitempty"` // AX subroles to exclude
	Apps     []string `yaml:"apps,omitempty" json:"apps,omitempty"`         // App names to exclude entirely
}

// LayoutConfig is the configuration representation of a layout
// Supports both explicit cells and areas syntax
type LayoutConfig struct {
	ID            string                     `yaml:"id" json:"id"`
	Name          string                     `yaml:"name" json:"name"`
	Description   string                     `yaml:"description,omitempty" json:"description,omitempty"`
	Grid          GridConfig                 `yaml:"grid" json:"grid"`
	Areas         [][]string                 `yaml:"areas,omitempty" json:"areas,omitempty"`               // ASCII grid syntax
	Cells         []CellConfig               `yaml:"cells,omitempty" json:"cells,omitempty"`               // Explicit cell definitions
	CellModes     map[string]types.StackMode `yaml:"cellModes,omitempty" json:"cellModes,omitempty"`
	Padding       interface{}                `yaml:"padding,omitempty" json:"padding,omitempty"`           // Layout-level default padding (supports shorthand)
	WindowSpacing interface{}                `yaml:"windowSpacing,omitempty" json:"windowSpacing,omitempty"` // Layout-level window spacing (supports shorthand)
}

// GridConfig defines the grid structure
type GridConfig struct {
	Columns []string `yaml:"columns" json:"columns"` // Track size strings
	Rows    []string `yaml:"rows" json:"rows"`       // Track size strings
}

// CellBorderConfigYAML is the YAML representation of per-cell border overrides
type CellBorderConfigYAML struct {
	ActiveCellColor *string `yaml:"active_cell_color,omitempty" json:"active_cell_color,omitempty"`
	InactiveColor   *string `yaml:"inactive_color,omitempty" json:"inactive_color,omitempty"`
	Style           *string `yaml:"style,omitempty" json:"style,omitempty"`
}

// CellConfig is the configuration representation of a cell
type CellConfig struct {
	ID            string                `yaml:"id" json:"id"`
	Column        string                `yaml:"column" json:"column"`                                    // "start/end" format, e.g., "1/3"
	Row           string                `yaml:"row" json:"row"`                                          // "start/end" format, e.g., "1/2"
	StackMode     types.StackMode       `yaml:"stackMode,omitempty" json:"stackMode,omitempty"`
	Padding       interface{}           `yaml:"padding,omitempty" json:"padding,omitempty"`              // Per-cell padding override (supports shorthand)
	WindowSpacing interface{}           `yaml:"windowSpacing,omitempty" json:"windowSpacing,omitempty"`  // Per-cell window spacing override (supports shorthand)
	Border        *CellBorderConfigYAML `yaml:"border,omitempty" json:"border,omitempty"`                // Per-cell border style override
}

// SpaceConfig defines per-Space settings
type SpaceConfig struct {
	Name          string   `yaml:"name,omitempty" json:"name,omitempty"`
	Layouts       []string `yaml:"layouts" json:"layouts"`             // Layout IDs available for this space
	DefaultLayout string   `yaml:"defaultLayout" json:"defaultLayout"` // Initial layout
	AutoApply     bool     `yaml:"autoApply" json:"autoApply"`         // Auto-apply on space switch
}

// AppRule defines application-specific window behavior
type AppRule struct {
	App                string          `yaml:"app" json:"app"`                                             // App name or bundle ID
	PreferredCell      string          `yaml:"preferredCell,omitempty" json:"preferredCell,omitempty"`
	Layouts            []string        `yaml:"layouts,omitempty" json:"layouts,omitempty"`                 // Only applies to these layouts
	Float              bool            `yaml:"float,omitempty" json:"float,omitempty"`                     // Never tile this app
	PreferredStackMode types.StackMode `yaml:"preferredStackMode,omitempty" json:"preferredStackMode,omitempty"`
}

// BorderConfig defines window border appearance
type BorderConfig struct {
	Enabled           *bool    `yaml:"enabled,omitempty" json:"enabled,omitempty"`
	Width             *float64 `yaml:"width,omitempty" json:"width,omitempty"`
	Style             *string  `yaml:"style,omitempty" json:"style,omitempty"`                         // round, square, uniform
	CornerRadius      *float64 `yaml:"corner_radius,omitempty" json:"corner_radius,omitempty"`
	Padding           *float64 `yaml:"padding,omitempty" json:"padding,omitempty"`
	HiDPI             *bool    `yaml:"hidpi,omitempty" json:"hidpi,omitempty"`
	ActiveWindowColor *string  `yaml:"active_window_color,omitempty" json:"active_window_color,omitempty"` // 0xAARRGGBB
	ActiveCellColor   *string  `yaml:"active_cell_color,omitempty" json:"active_cell_color,omitempty"`
	InactiveColor     *string  `yaml:"inactive_color,omitempty" json:"inactive_color,omitempty"`
	Palette           []string `yaml:"palette,omitempty" json:"palette,omitempty"`
	Whitelist         []string `yaml:"whitelist,omitempty" json:"whitelist,omitempty"`
	Blacklist         []string `yaml:"blacklist,omitempty" json:"blacklist,omitempty"`
}

// GetEnabled returns the enabled state, defaulting to false if not set
func (b *BorderConfig) GetEnabled() bool {
	if b == nil || b.Enabled == nil {
		return false
	}
	return *b.Enabled
}

// GetWidth returns the border width, defaulting to 5.0 if not set
func (b *BorderConfig) GetWidth() float64 {
	if b == nil || b.Width == nil {
		return 5.0
	}
	return *b.Width
}

// GetStyle returns the border style, defaulting to "round" if not set
func (b *BorderConfig) GetStyle() string {
	if b == nil || b.Style == nil {
		return "round"
	}
	return *b.Style
}

// GetCornerRadius returns the corner radius, defaulting to 8.0 if not set
func (b *BorderConfig) GetCornerRadius() float64 {
	if b == nil || b.CornerRadius == nil {
		return 8.0
	}
	return *b.CornerRadius
}

// GetPadding returns the padding, defaulting to 2.0 if not set
func (b *BorderConfig) GetPadding() float64 {
	if b == nil || b.Padding == nil {
		return 2.0
	}
	return *b.Padding
}

// GetHiDPI returns the HiDPI setting, defaulting to true if not set
func (b *BorderConfig) GetHiDPI() bool {
	if b == nil || b.HiDPI == nil {
		return true
	}
	return *b.HiDPI
}
