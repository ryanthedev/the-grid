package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"

	"github.com/ryanthedev/grid-cli/internal/xdg"
)

// SaveLayoutOverride writes a layout override to config.local.yaml.
// Reads the existing local config (or starts with an empty map),
// sets layoutOverrides.<layoutID>, and writes back atomically.
// Invalidates the config cache afterwards.
func SaveLayoutOverride(layoutID string, override LayoutOverrideConfig) error {
	localPath := filepath.Join(xdg.ConfigHome(), "thegrid", "config.local.yaml")

	// Read existing local config as raw map to preserve other fields
	existing := make(map[string]any)
	if data, err := os.ReadFile(localPath); err == nil {
		if err := yaml.Unmarshal(data, &existing); err != nil {
			return fmt.Errorf("failed to parse existing config.local.yaml: %w", err)
		}
	}
	// If file doesn't exist, we start with empty map (already initialized)

	// Marshal the override struct to map[string]any via YAML round-trip
	overrideBytes, err := yaml.Marshal(override)
	if err != nil {
		return fmt.Errorf("failed to marshal override: %w", err)
	}
	var overrideMap map[string]any
	if err := yaml.Unmarshal(overrideBytes, &overrideMap); err != nil {
		return fmt.Errorf("failed to unmarshal override to map: %w", err)
	}

	// Get or create layoutOverrides section
	overrides, ok := existing["layoutOverrides"].(map[string]any)
	if !ok {
		overrides = make(map[string]any)
	}
	// Merge with existing override for this layout (preserves fields from
	// previous saves, e.g. cell modes saved earlier when only ratios changed now)
	if existingOverride, ok := overrides[layoutID].(map[string]any); ok {
		overrideMap = deepMerge(existingOverride, overrideMap)
	}
	overrides[layoutID] = overrideMap
	existing["layoutOverrides"] = overrides

	// Marshal back to YAML
	data, err := yaml.Marshal(existing)
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Ensure directory exists
	dir := filepath.Dir(localPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	// Atomic write: temp file + rename
	tmpPath := localPath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("failed to write temp file: %w", err)
	}
	if err := os.Rename(tmpPath, localPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to rename temp file: %w", err)
	}

	// Invalidate config cache
	InvalidateCache()

	return nil
}

// InvalidateCache removes the merged config cache file so it gets rebuilt on next load.
func InvalidateCache() {
	os.Remove(cachePath())
}
