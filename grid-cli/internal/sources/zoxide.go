package sources

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// DiscoverZoxide returns directories from zoxide's frecency database
func DiscoverZoxide() []SourceItem {
	cmd := exec.Command("zoxide", "query", "-l")
	out, err := cmd.Output()
	if err != nil {
		jsonlog.Log("sources.zoxide.err", jsonlog.WithMsg("failed to query zoxide"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		return nil
	}

	home, _ := os.UserHomeDir()

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
