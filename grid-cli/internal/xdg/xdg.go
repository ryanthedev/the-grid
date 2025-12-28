package xdg

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// ConfigHome returns $XDG_CONFIG_HOME or ~/.config
func ConfigHome() string {
	if env := os.Getenv("XDG_CONFIG_HOME"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config")
}

// ConfigDirs returns validated $XDG_CONFIG_DIRS as slice, or platform defaults.
// Filters out empty segments and relative paths per XDG spec.
func ConfigDirs() []string {
	var dirs []string

	if env := os.Getenv("XDG_CONFIG_DIRS"); env != "" {
		for _, d := range strings.Split(env, ":") {
			// Skip empty segments and relative paths
			if d == "" || !filepath.IsAbs(d) {
				continue
			}
			dirs = append(dirs, d)
		}
		if len(dirs) > 0 {
			return dedup(dirs)
		}
	}

	// Platform defaults
	dirs = []string{"/etc/xdg"}
	if runtime.GOOS == "darwin" {
		dirs = append(dirs, "/opt/homebrew/etc", "/usr/local/etc")
	}
	return dirs
}

// StateHome returns $XDG_STATE_HOME or ~/.local/state
func StateHome() string {
	if env := os.Getenv("XDG_STATE_HOME"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state")
}

// CacheHome returns $XDG_CACHE_HOME or ~/.cache
func CacheHome() string {
	if env := os.Getenv("XDG_CACHE_HOME"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache")
}

// FindConfigFiles returns existing config files in merge order (system -> user).
// Logs warnings for permission errors, silently skips missing files.
func FindConfigFiles(appName, filename string) []string {
	var paths []string
	seen := make(map[string]bool)

	// System dirs (reverse so first entry in XDG_CONFIG_DIRS has highest priority)
	dirs := ConfigDirs()
	for i := len(dirs) - 1; i >= 0; i-- {
		path := filepath.Join(dirs[i], appName, filename)
		if seen[path] {
			continue
		}
		seen[path] = true

		info, err := os.Stat(path)
		if err != nil {
			if !os.IsNotExist(err) {
				// Permission error or other issue - log and skip
				jsonlog.Log("cfg.skip", jsonlog.WithMsg("cannot access file"),
					jsonlog.WithData(map[string]any{"path": path, "err": err.Error()}))
			}
			continue
		}
		if info.IsDir() {
			continue
		}
		paths = append(paths, path)
	}

	// User config
	userPath := filepath.Join(ConfigHome(), appName, filename)
	if !seen[userPath] {
		info, err := os.Stat(userPath)
		if err != nil {
			if !os.IsNotExist(err) {
				jsonlog.Log("cfg.skip", jsonlog.WithMsg("cannot access file"),
					jsonlog.WithData(map[string]any{"path": userPath, "err": err.Error()}))
			}
		} else if !info.IsDir() {
			paths = append(paths, userPath)
		}
	}

	return paths
}

// dedup removes duplicate paths while preserving order
func dedup(paths []string) []string {
	seen := make(map[string]bool)
	var result []string
	for _, p := range paths {
		if !seen[p] {
			seen[p] = true
			result = append(result, p)
		}
	}
	return result
}
