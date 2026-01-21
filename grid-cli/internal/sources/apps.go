package sources

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"howett.net/plist"
)

// DiscoverApps scans standard macOS directories for .app bundles
func DiscoverApps() []SourceItem {
	home, err := os.UserHomeDir()
	if err != nil {
		jsonlog.Log("sources.apps.err", jsonlog.WithMsg("failed to get home dir"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		home = ""
	}

	dirs := []string{
		"/Applications",
		"/System/Applications",
	}
	if home != "" {
		dirs = append(dirs, filepath.Join(home, "Applications"))
	}

	var items []SourceItem
	seen := make(map[string]bool)

	for _, dir := range dirs {
		apps := scanAppDir(dir)
		for _, app := range apps {
			if seen[app.ID] {
				continue
			}
			seen[app.ID] = true
			items = append(items, app)
		}
	}

	return items
}

func scanAppDir(dir string) []SourceItem {
	entries, err := os.ReadDir(dir)
	if err != nil {
		// Directory might not exist (e.g., ~/Applications)
		return nil
	}

	var items []SourceItem
	for _, entry := range entries {
		if !entry.IsDir() || !strings.HasSuffix(entry.Name(), ".app") {
			continue
		}

		appPath := filepath.Join(dir, entry.Name())
		item := parseAppBundle(appPath)
		if item != nil {
			items = append(items, *item)
		}
	}

	return items
}

type infoPlist struct {
	BundleID   string `plist:"CFBundleIdentifier"`
	BundleName string `plist:"CFBundleName"`
	DisplayName string `plist:"CFBundleDisplayName"`
}

func parseAppBundle(appPath string) *SourceItem {
	plistPath := filepath.Join(appPath, "Contents", "Info.plist")
	f, err := os.Open(plistPath)
	if err != nil {
		jsonlog.Log("sources.apps.plist.err", jsonlog.WithMsg("failed to open plist"), jsonlog.WithData(map[string]any{"path": appPath, "err": err.Error()}))
		return nil
	}
	defer f.Close()

	var info infoPlist
	decoder := plist.NewDecoder(f)
	if err := decoder.Decode(&info); err != nil {
		jsonlog.Log("sources.apps.plist.err", jsonlog.WithMsg("failed to decode plist"), jsonlog.WithData(map[string]any{"path": appPath, "err": err.Error()}))
		return nil
	}

	if info.BundleID == "" {
		return nil
	}

	// Determine display name
	name := info.DisplayName
	if name == "" {
		name = info.BundleName
	}
	if name == "" {
		// Fall back to app filename without .app
		name = strings.TrimSuffix(filepath.Base(appPath), ".app")
	}

	// Build searchable terms
	searchable := []string{strings.ToLower(name)}
	if info.BundleID != "" {
		searchable = append(searchable, strings.ToLower(info.BundleID))
	}

	return &SourceItem{
		ID:         "app:" + info.BundleID,
		Title:      name,
		Subtitle:   info.BundleID,
		Icon:       "bundle:" + info.BundleID,
		Searchable: searchable,
		Action: Action{
			Type:    "open-app",
			AppPath: appPath,
		},
		Metadata: map[string]string{
			"bundleId": info.BundleID,
			"path":     appPath,
		},
	}
}
