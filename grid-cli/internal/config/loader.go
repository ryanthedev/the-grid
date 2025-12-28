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

// loadWithXDG implements full XDG config resolution with layered merging and caching
func loadWithXDG() (*Config, error) {
	// Check cache freshness (single call to avoid TOCTOU)
	fresh, reason := isCacheFresh()
	if fresh {
		merged, err := loadCache()
		if err == nil {
			jsonlog.Log("cfg.cache.hit")
			cfg, err := mapToConfig(merged)
			if err != nil {
				return nil, fmt.Errorf("failed to unmarshal cached config: %w", err)
			}
			if err := cfg.Validate(); err != nil {
				// Cache is corrupt or schema changed - rebuild
				jsonlog.Log("cfg.cache.miss", jsonlog.WithData(map[string]any{"reason": "validation_failed"}))
			} else {
				return cfg, nil
			}
		} else {
			jsonlog.Log("cfg.cache.miss", jsonlog.WithData(map[string]any{"reason": "read_error"}))
		}
	} else {
		jsonlog.Log("cfg.cache.miss", jsonlog.WithData(map[string]any{"reason": reason}))
	}

	// Cache miss - do full resolution
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

	// Write cache using getSourceFiles() for consistency (ignore errors - best-effort)
	if err := writeCache(merged, getSourceFiles()); err != nil {
		jsonlog.Log("cfg.cache.error", jsonlog.WithMsg("failed to write cache"),
			jsonlog.WithData(map[string]any{"err": err.Error()}))
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

// cachePath returns the path to the merged config cache file
func cachePath() string {
	return filepath.Join(xdg.CacheHome(), "thegrid", "config.merged.yaml")
}

// getSourceFiles returns all config source files that contribute to merged config
func getSourceFiles() []string {
	files := xdg.FindConfigFiles("thegrid", "config.yaml")
	localPath := filepath.Join(xdg.ConfigHome(), "thegrid", "config.local.yaml")
	if info, err := os.Stat(localPath); err == nil && !info.IsDir() {
		files = append(files, localPath)
	}
	return files
}

// isCacheFresh checks if cache exists and is newer than all source files.
// Returns (isFresh, reason) where reason explains why cache is stale.
func isCacheFresh() (bool, string) {
	cache := cachePath()
	cacheInfo, err := os.Stat(cache)
	if err != nil {
		if os.IsNotExist(err) {
			return false, "missing"
		}
		return false, "stat_error"
	}
	cacheMtime := cacheInfo.ModTime()

	sources := getSourceFiles()
	if len(sources) == 0 {
		return false, "no_sources"
	}

	for _, src := range sources {
		srcInfo, err := os.Stat(src)
		if err != nil {
			return false, "source_deleted"
		}
		if srcInfo.ModTime().After(cacheMtime) {
			return false, "stale"
		}
	}

	return true, ""
}

// writeCache writes the merged config map to cache file atomically
func writeCache(merged map[string]any, sources []string) error {
	cache := cachePath()
	dir := filepath.Dir(cache)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create cache dir: %w", err)
	}

	data, err := yaml.Marshal(merged)
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Atomic write: write to temp file, then rename
	tmp := cache + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return fmt.Errorf("failed to write cache: %w", err)
	}
	if err := os.Rename(tmp, cache); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("failed to rename cache: %w", err)
	}

	jsonlog.Log("cfg.cache.write", jsonlog.WithData(map[string]any{
		"path":    cache,
		"sources": sources,
	}))

	return nil
}

// loadCache reads the cached merged config
func loadCache() (map[string]any, error) {
	data, err := os.ReadFile(cachePath())
	if err != nil {
		return nil, err
	}

	var m map[string]any
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, err
	}

	return m, nil
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

// ConfigSource represents a config file source
type ConfigSource struct {
	Path   string
	Type   string // "system", "user", "local"
	Exists bool
}

// GetConfigSources returns all potential config sources in merge order
func GetConfigSources() []ConfigSource {
	var sources []ConfigSource

	files := xdg.FindConfigFiles("thegrid", "config.yaml")
	configHome := xdg.ConfigHome()
	configDirs := xdg.ConfigDirs()

	userPath := filepath.Join(configHome, "thegrid", "config.yaml")
	localPath := filepath.Join(configHome, "thegrid", "config.local.yaml")

	existingFiles := make(map[string]bool)
	for _, f := range files {
		existingFiles[f] = true
	}

	for _, dir := range configDirs {
		path := filepath.Join(dir, "thegrid", "config.yaml")
		exists := existingFiles[path]
		sources = append(sources, ConfigSource{
			Path:   path,
			Type:   "system",
			Exists: exists,
		})
	}

	sources = append(sources, ConfigSource{
		Path:   userPath,
		Type:   "user",
		Exists: existingFiles[userPath],
	})

	if info, err := os.Stat(localPath); err == nil && !info.IsDir() {
		sources = append(sources, ConfigSource{
			Path:   localPath,
			Type:   "local",
			Exists: true,
		})
	} else {
		sources = append(sources, ConfigSource{
			Path:   localPath,
			Type:   "local",
			Exists: false,
		})
	}

	return sources
}
