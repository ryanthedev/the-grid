package sources

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// findZoxideBinary locates the zoxide executable
// Priority: 1) config override, 2) PATH, 3) common install locations
func findZoxideBinary(configuredPath string) (string, error) {
	// If config override exists, use it unconditionally
	if configuredPath != "" {
		if _, err := os.Stat(configuredPath); err == nil {
			jsonlog.Log("sources.zoxide.path", jsonlog.WithMsg("using configured path"), jsonlog.WithData(map[string]any{"path": configuredPath}))
			return configuredPath, nil
		}
		return "", fmt.Errorf("configured zoxide path not found: %s", configuredPath)
	}

	// Try PATH lookup first
	if path, err := exec.LookPath("zoxide"); err == nil {
		jsonlog.Log("sources.zoxide.path", jsonlog.WithMsg("found in PATH"), jsonlog.WithData(map[string]any{"path": path}))
		return path, nil
	}

	// Fall back to common installation locations
	home, err := os.UserHomeDir()
	if err != nil {
		jsonlog.Log("sources.zoxide.warn", jsonlog.WithMsg("could not determine home directory"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		home = ""
	}
	fallbackPaths := []string{}
	if home != "" {
		fallbackPaths = append(fallbackPaths, filepath.Join(home, ".cargo", "bin", "zoxide"))
	}
	fallbackPaths = append(fallbackPaths,
		"/opt/homebrew/bin/zoxide",
		"/usr/local/bin/zoxide",
	)

	for _, path := range fallbackPaths {
		if _, err := os.Stat(path); err == nil {
			jsonlog.Log("sources.zoxide.path", jsonlog.WithMsg("found in fallback location"), jsonlog.WithData(map[string]any{"path": path}))
			return path, nil
		}
	}

	// Nothing found
	jsonlog.Log("sources.zoxide.err", jsonlog.WithMsg("zoxide not found in PATH or fallback locations"))
	return "", fmt.Errorf("zoxide not found in PATH or fallback locations")
}

// DiscoverZoxide returns directories from zoxide's frecency database
func DiscoverZoxide(configuredPath string) []SourceItem {
	zoxidePath, err := findZoxideBinary(configuredPath)
	if err != nil {
		jsonlog.Log("sources.zoxide.err", jsonlog.WithMsg("failed to find zoxide binary"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		return nil
	}

	cmd := exec.Command(zoxidePath, "query", "-l")
	out, err := cmd.Output()
	if err != nil {
		jsonlog.Log("sources.zoxide.err", jsonlog.WithMsg("failed to query zoxide"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		return nil
	}

	home, err := os.UserHomeDir()
	if err != nil {
		jsonlog.Log("sources.zoxide.warn", jsonlog.WithMsg("failed to get home directory for display"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		home = ""
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var items []SourceItem

	for _, line := range lines {
		dir := strings.TrimSpace(line)
		if dir == "" {
			continue
		}

		// Create display name - use tilde for home paths
		display := dir
		if home != "" && strings.HasPrefix(dir, home) {
			display = "~" + strings.TrimPrefix(dir, home)
		}

		// Title is the last path component
		title := filepath.Base(dir)

		// ID uses the display path for uniqueness
		id := "zoxide:" + display

		items = append(items, SourceItem{
			ID:         id,
			Title:      title,
			Subtitle:   display,
			Icon:       "folder",
			Searchable: []string{strings.ToLower(title), strings.ToLower(display)},
			Action: Action{
				Type:    "open-dir",
				DirPath: dir,
			},
			Metadata: map[string]string{
				"path": dir,
			},
		})
	}

	return items
}
