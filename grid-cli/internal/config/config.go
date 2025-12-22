package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/viper"
	"gopkg.in/yaml.v3"

	"github.com/yourusername/grid-cli/internal/types"
)

const (
	DefaultConfigDir  = ".config/thegrid"
	DefaultConfigFile = "config.yaml"
)

// LoadConfig loads configuration from the specified path or default location
// If path is empty, uses ~/.config/thegrid/config.yaml
// Supports both .yaml and .json extensions
// Automatically merges config.local.yaml if it exists (for machine-specific overrides)
func LoadConfig(path string) (*Config, error) {
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("cannot determine home directory: %w", err)
		}
		// Try YAML first, then JSON
		yamlPath := filepath.Join(home, DefaultConfigDir, "config.yaml")
		jsonPath := filepath.Join(home, DefaultConfigDir, "config.json")

		if _, err := os.Stat(yamlPath); err == nil {
			path = yamlPath
		} else if _, err := os.Stat(jsonPath); err == nil {
			path = jsonPath
		} else {
			return nil, fmt.Errorf("no config file found at %s or %s", yamlPath, jsonPath)
		}
	}

	ext := strings.ToLower(filepath.Ext(path))

	// For YAML files, support layered config via Viper
	if ext == ".yaml" || ext == ".yml" {
		return loadLayeredConfig(path)
	}

	// JSON files: load directly (no layering for now)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse JSON config: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

// loadLayeredConfig loads base config and merges .local.yaml overlay if present using Viper
func loadLayeredConfig(basePath string) (*Config, error) {
	v := viper.New()

	// Configure viper for the base config
	dir := filepath.Dir(basePath)
	base := filepath.Base(basePath)
	ext := filepath.Ext(base)
	name := strings.TrimSuffix(base, ext)

	v.SetConfigName(name)
	v.SetConfigType(strings.TrimPrefix(ext, "."))
	v.AddConfigPath(dir)

	// Load base config
	if err := v.ReadInConfig(); err != nil {
		return nil, fmt.Errorf("failed to load base config: %w", err)
	}

	// Check for and merge local override file
	localPath := filepath.Join(dir, name+".local"+ext)
	if _, err := os.Stat(localPath); err == nil {
		v.SetConfigFile(localPath)
		if err := v.MergeInConfig(); err != nil {
			return nil, fmt.Errorf("failed to merge local config %s: %w", localPath, err)
		}
	}

	// Unmarshal to Config struct
	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

// LoadConfigFromBytes loads configuration from raw bytes
// format should be "yaml" or "json"
func LoadConfigFromBytes(data []byte, format string) (*Config, error) {
	var cfg Config

	switch format {
	case "yaml", "yml":
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return nil, fmt.Errorf("failed to parse YAML config: %w", err)
		}
	case "json":
		if err := json.Unmarshal(data, &cfg); err != nil {
			return nil, fmt.Errorf("failed to parse JSON config: %w", err)
		}
	default:
		return nil, fmt.Errorf("unsupported config format: %s", format)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

// GetConfigPath returns the default config file path
func GetConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, DefaultConfigDir, DefaultConfigFile)
}

// GetLayout returns a layout by ID, converting from LayoutConfig to types.Layout
func (c *Config) GetLayout(id string) (*types.Layout, error) {
	// Check user layouts first
	for _, lc := range c.Layouts {
		if lc.ID == id {
			return lc.ToLayout()
		}
	}
	// Check builtins
	if builtin := GetBuiltinLayout(id); builtin != nil {
		return builtin.ToLayout()
	}
	return nil, fmt.Errorf("layout not found: %s", id)
}

// GetLayoutIDs returns all available layout IDs
func (c *Config) GetLayoutIDs() []string {
	ids := make([]string, len(c.Layouts))
	for i, l := range c.Layouts {
		ids[i] = l.ID
	}
	return ids
}

// GetSpaceConfig returns configuration for a specific space
func (c *Config) GetSpaceConfig(spaceID string) *SpaceConfig {
	if sc, ok := c.Spaces[spaceID]; ok {
		return &sc
	}
	return nil
}

// GetAppRule finds the first matching app rule
func (c *Config) GetAppRule(appName, bundleID string) *AppRule {
	for _, rule := range c.AppRules {
		if rule.App == appName || rule.App == bundleID {
			return &rule
		}
	}
	return nil
}

// ToLayout converts LayoutConfig to types.Layout
func (lc *LayoutConfig) ToLayout() (*types.Layout, error) {
	// Parse columns
	columns := make([]types.TrackSize, len(lc.Grid.Columns))
	for i, col := range lc.Grid.Columns {
		ts, err := ParseTrackSize(col)
		if err != nil {
			return nil, fmt.Errorf("invalid column %d: %w", i, err)
		}
		columns[i] = ts
	}

	// Parse rows
	rows := make([]types.TrackSize, len(lc.Grid.Rows))
	for i, row := range lc.Grid.Rows {
		ts, err := ParseTrackSize(row)
		if err != nil {
			return nil, fmt.Errorf("invalid row %d: %w", i, err)
		}
		rows[i] = ts
	}

	// Parse layout-level padding
	var layoutPadding *types.Padding
	if lc.Padding != nil {
		var err error
		layoutPadding, err = ParsePadding(lc.Padding)
		if err != nil {
			return nil, fmt.Errorf("invalid layout padding: %w", err)
		}
	}

	// Parse layout-level windowSpacing
	var layoutWindowSpacing *types.PaddingValue
	if lc.WindowSpacing != nil {
		pv, err := parseSinglePaddingValue(lc.WindowSpacing)
		if err != nil {
			return nil, fmt.Errorf("invalid layout windowSpacing: %w", err)
		}
		layoutWindowSpacing = &pv
	}

	// Parse cells (either from explicit cells or areas)
	var cells []types.Cell
	if len(lc.Areas) > 0 {
		cells = AreasToCell(lc.Areas)
		// Note: areas syntax doesn't support per-cell padding directly
		// Users must use explicit cells for per-cell padding
	} else {
		cells = make([]types.Cell, len(lc.Cells))
		for i, cc := range lc.Cells {
			cell, err := cc.ToCell()
			if err != nil {
				return nil, fmt.Errorf("invalid cell %s: %w", cc.ID, err)
			}
			cells[i] = cell
		}
	}

	return &types.Layout{
		ID:            lc.ID,
		Name:          lc.Name,
		Description:   lc.Description,
		Columns:       columns,
		Rows:          rows,
		Cells:         cells,
		CellModes:     lc.CellModes,
		Padding:       layoutPadding,
		WindowSpacing: layoutWindowSpacing,
	}, nil
}

// ToCell converts CellConfig to types.Cell
func (cc *CellConfig) ToCell() (types.Cell, error) {
	colStart, colEnd, err := parseSpan(cc.Column)
	if err != nil {
		return types.Cell{}, fmt.Errorf("invalid column span: %w", err)
	}

	rowStart, rowEnd, err := parseSpan(cc.Row)
	if err != nil {
		return types.Cell{}, fmt.Errorf("invalid row span: %w", err)
	}

	// Parse cell-level padding
	var cellPadding *types.Padding
	if cc.Padding != nil {
		cellPadding, err = ParsePadding(cc.Padding)
		if err != nil {
			return types.Cell{}, fmt.Errorf("invalid cell padding: %w", err)
		}
	}

	// Parse cell-level windowSpacing
	var cellWindowSpacing *types.PaddingValue
	if cc.WindowSpacing != nil {
		pv, err := parseSinglePaddingValue(cc.WindowSpacing)
		if err != nil {
			return types.Cell{}, fmt.Errorf("invalid cell windowSpacing: %w", err)
		}
		cellWindowSpacing = &pv
	}

	// Convert cell-level border config
	var cellBorder *types.CellBorderConfig
	if cc.Border != nil {
		cellBorder = &types.CellBorderConfig{
			ActiveCellColor: cc.Border.ActiveCellColor,
			InactiveColor:   cc.Border.InactiveColor,
			Style:           cc.Border.Style,
		}
	}

	return types.Cell{
		ID:            cc.ID,
		ColumnStart:   colStart,
		ColumnEnd:     colEnd,
		RowStart:      rowStart,
		RowEnd:        rowEnd,
		StackMode:     cc.StackMode,
		Padding:       cellPadding,
		WindowSpacing: cellWindowSpacing,
		Border:        cellBorder,
	}, nil
}

// GetSettingsPadding parses and returns the global settings padding
func (c *Config) GetSettingsPadding() (*types.Padding, error) {
	if c.Settings.Padding == nil {
		return nil, nil
	}
	return ParsePadding(c.Settings.Padding)
}

// GetBaseSpacing returns the base spacing value from settings
// Returns 8 as default if not configured
func (c *Config) GetBaseSpacing() float64 {
	if c.Settings.BaseSpacing > 0 {
		return c.Settings.BaseSpacing
	}
	return 8 // Default base spacing
}

// GetSettingsWindowSpacing parses and returns the global settings window spacing
func (c *Config) GetSettingsWindowSpacing() (*types.PaddingValue, error) {
	if c.Settings.WindowSpacing == nil {
		return nil, nil
	}
	pv, err := parseSinglePaddingValue(c.Settings.WindowSpacing)
	if err != nil {
		return nil, err
	}
	return &pv, nil
}

// DefaultWindowExclusions returns sensible defaults for window exclusion.
// These filter out transient windows that shouldn't be tiled.
var DefaultWindowExclusions = WindowExclusion{
	Roles: []string{
		"AXHelpTag",    // Tooltips
		"AXGrowArea",   // Resize handles
		"AXScrollArea", // Scroll indicators
	},
	Subroles: []string{}, // User can add specific subroles
	Apps: []string{
		"Dock",
		"Control Center",
		"Notification Center",
	},
}

// GetWindowExclusions returns the configured window exclusions merged with defaults.
// User config adds to defaults, doesn't replace them.
func (c *Config) GetWindowExclusions() WindowExclusion {
	result := WindowExclusion{
		Roles:    append([]string{}, DefaultWindowExclusions.Roles...),
		Subroles: append([]string{}, DefaultWindowExclusions.Subroles...),
		Apps:     append([]string{}, DefaultWindowExclusions.Apps...),
	}

	// Merge user config (additive)
	for _, r := range c.Settings.WindowExclusion.Roles {
		if !containsString(result.Roles, r) {
			result.Roles = append(result.Roles, r)
		}
	}
	for _, s := range c.Settings.WindowExclusion.Subroles {
		if !containsString(result.Subroles, s) {
			result.Subroles = append(result.Subroles, s)
		}
	}
	for _, a := range c.Settings.WindowExclusion.Apps {
		if !containsString(result.Apps, a) {
			result.Apps = append(result.Apps, a)
		}
	}

	return result
}

func containsString(slice []string, s string) bool {
	for _, item := range slice {
		if item == s {
			return true
		}
	}
	return false
}
