package config

import "github.com/yourusername/grid-cli/internal/types"

// Config is the root configuration structure
type Config struct {
	Settings Settings               `yaml:"settings" json:"settings"`
	Layouts  []LayoutConfig         `yaml:"layouts" json:"layouts"`
	Spaces   map[string]SpaceConfig `yaml:"spaces" json:"spaces"`
	AppRules []AppRule              `yaml:"appRules" json:"appRules"`
}

// Settings contains global application settings
type Settings struct {
	DefaultStackMode  types.StackMode `yaml:"defaultStackMode" json:"defaultStackMode"`
	AnimationDuration float64         `yaml:"animationDuration" json:"animationDuration"`
	BaseSpacing       float64         `yaml:"baseSpacing" json:"baseSpacing"`                         // Base unit for "Nx" padding syntax
	Padding           interface{}     `yaml:"padding,omitempty" json:"padding,omitempty"`             // Global default padding (supports shorthand)
	WindowSpacing     interface{}     `yaml:"windowSpacing,omitempty" json:"windowSpacing,omitempty"` // Gap between stacked windows (supports shorthand)
	FocusFollowsMouse bool            `yaml:"focusFollowsMouse" json:"focusFollowsMouse"`
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

// CellConfig is the configuration representation of a cell
type CellConfig struct {
	ID            string          `yaml:"id" json:"id"`
	Column        string          `yaml:"column" json:"column"`                               // "start/end" format, e.g., "1/3"
	Row           string          `yaml:"row" json:"row"`                                     // "start/end" format, e.g., "1/2"
	StackMode     types.StackMode `yaml:"stackMode,omitempty" json:"stackMode,omitempty"`
	Padding       interface{}     `yaml:"padding,omitempty" json:"padding,omitempty"`         // Per-cell padding override (supports shorthand)
	WindowSpacing interface{}     `yaml:"windowSpacing,omitempty" json:"windowSpacing,omitempty"` // Per-cell window spacing override (supports shorthand)
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
