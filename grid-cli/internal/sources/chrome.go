package sources

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// chromeLocalState represents the Chrome Local State JSON structure
type chromeLocalState struct {
	Profile struct {
		InfoCache map[string]chromeProfileInfo `json:"info_cache"`
	} `json:"profile"`
}

type chromeProfileInfo struct {
	Name           string `json:"name"`
	ShortcutName   string `json:"shortcut_name"`
	GAIAName       string `json:"gaia_name"`
	UserName       string `json:"user_name"`
	IsUsingDefault bool   `json:"is_using_default_name"`
}

// DiscoverChromeProfiles parses Chrome's Local State to find profiles
func DiscoverChromeProfiles() []SourceItem {
	home, err := os.UserHomeDir()
	if err != nil {
		jsonlog.Log("sources.chrome.err", jsonlog.WithMsg("failed to get home dir"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		return nil
	}

	localStatePath := filepath.Join(home, "Library", "Application Support", "Google", "Chrome", "Local State")
	f, err := os.Open(localStatePath)
	if err != nil {
		// Chrome not installed or Local State doesn't exist - not an error
		return nil
	}
	defer f.Close()

	var state chromeLocalState
	if err := json.NewDecoder(f).Decode(&state); err != nil {
		jsonlog.Log("sources.chrome.err", jsonlog.WithMsg("failed to decode Local State"), jsonlog.WithData(map[string]any{"err": err.Error()}))
		return nil
	}

	var items []SourceItem
	for profileDir, info := range state.Profile.InfoCache {
		// Determine best display name
		name := info.Name
		if name == "" || info.IsUsingDefault {
			if info.GAIAName != "" {
				name = info.GAIAName
			} else if info.ShortcutName != "" {
				name = info.ShortcutName
			} else if info.UserName != "" {
				name = info.UserName
			}
		}
		if name == "" {
			name = profileDir
		}

		// Build searchable terms
		searchable := []string{strings.ToLower(name), "chrome", "browser"}
		if info.GAIAName != "" && info.GAIAName != name {
			searchable = append(searchable, strings.ToLower(info.GAIAName))
		}
		if info.UserName != "" {
			searchable = append(searchable, strings.ToLower(info.UserName))
		}

		items = append(items, SourceItem{
			ID:         "chrome:" + profileDir,
			Title:      name,
			Subtitle:   "Chrome Profile",
			Icon:       "bundle:com.google.Chrome",
			Searchable: searchable,
			Action: Action{
				Type:       "open-chrome-profile",
				ProfileDir: profileDir,
			},
			Metadata: map[string]string{
				"profileDir": profileDir,
			},
		})
	}

	return items
}
