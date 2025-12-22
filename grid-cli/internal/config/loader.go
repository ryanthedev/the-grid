package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/xdg"
)

// LoadConfig loads configuration using XDG resolution.
// If path is provided, bypasses XDG and loads only that file (no layering).
func LoadConfig(path string) (*Config, error) {
	if path != "" {
		return loadSingleFile(path)
	}
	return loadWithXDG()
}

// loadWithXDG implements full XDG config resolution with layered merging
func loadWithXDG() (*Config, error) {
	files := xdg.FindConfigFiles("thegrid", "config.yaml")

	merged := builtinDefaults()

	jsonlog.Log("cfg.resolve", jsonlog.WithData(map[string]any{
		"xdg_config_home": xdg.ConfigHome(),
		"xdg_config_dirs": xdg.ConfigDirs(),
		"files_found":     files,
	}))

	for _, f := range files {
		layer, err := loadYAMLFile(f)
		if err != nil {
			return nil, fmt.Errorf("failed to parse %s: %w", f, err)
		}
		merged = deepMerge(merged, layer)
		jsonlog.Log("cfg.merge", jsonlog.WithData(map[string]any{"path": f}))
	}

	localPath := filepath.Join(xdg.ConfigHome(), "thegrid", "config.local.yaml")
	if info, err := os.Stat(localPath); err == nil && !info.IsDir() {
		layer, err := loadYAMLFile(localPath)
		if err != nil {
			return nil, fmt.Errorf("failed to parse %s: %w", localPath, err)
		}
		merged = deepMerge(merged, layer)
		jsonlog.Log("cfg.merge", jsonlog.WithData(map[string]any{"path": localPath, "layer": "local"}))
	}

	if len(files) == 0 {
		localInfo, _ := os.Stat(localPath)
		if localInfo == nil {
			return nil, fmt.Errorf("no config found; searched:\n  - %s/thegrid/config.yaml\n  - %s",
				xdg.ConfigHome(), formatSearchedDirs(xdg.ConfigDirs()))
		}
	}

	cfg, err := mapToConfig(merged)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal merged config: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config after merge: %w", err)
	}

	return cfg, nil
}

// loadSingleFile loads a single config file without layering
func loadSingleFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

// loadYAMLFile reads a YAML file into a map
func loadYAMLFile(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var m map[string]any
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, err
	}

	return m, nil
}

// builtinDefaults returns hardcoded default values
func builtinDefaults() map[string]any {
	return map[string]any{
		"settings": map[string]any{
			"baseSpacing": 8,
		},
	}
}

// deepMerge merges override into base recursively.
// - Objects: merge recursively
// - Arrays: override replaces base
// - null: removes key from result
// - Scalars: override wins
func deepMerge(base, override map[string]any) map[string]any {
	result := make(map[string]any)

	for k, v := range base {
		result[k] = v
	}

	for k, v := range override {
		if v == nil {
			delete(result, k)
			continue
		}

		baseVal, exists := result[k]
		if !exists {
			result[k] = v
			continue
		}

		baseMap, baseIsMap := baseVal.(map[string]any)
		overrideMap, overrideIsMap := v.(map[string]any)
		if baseIsMap && overrideIsMap {
			result[k] = deepMerge(baseMap, overrideMap)
		} else {
			result[k] = v
		}
	}

	return result
}

// mapToConfig converts a map[string]any to Config struct
func mapToConfig(m map[string]any) (*Config, error) {
	data, err := yaml.Marshal(m)
	if err != nil {
		return nil, err
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}

	return &cfg, nil
}

func formatSearchedDirs(dirs []string) string {
	var result string
	for _, d := range dirs {
		result += fmt.Sprintf("  - %s/thegrid/config.yaml\n", d)
	}
	return result
}
