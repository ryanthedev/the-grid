package sources

import (
	"strings"

	gridConfig "github.com/ryanthedev/grid-cli/internal/config"
)

// DiscoverActions transforms ActionConfig slice into SourceItems
func DiscoverActions(configs []gridConfig.ActionConfig) []SourceItem {
	if len(configs) == 0 {
		return nil
	}

	items := make([]SourceItem, 0, len(configs))
	for _, cfg := range configs {
		if cfg.Name == "" || cfg.Command == "" {
			continue
		}

		// Build searchable terms
		searchable := []string{strings.ToLower(cfg.Name)}
		if cfg.Category != "" {
			searchable = append(searchable, strings.ToLower(cfg.Category))
		}
		// Add individual words from the name
		for _, word := range strings.Fields(cfg.Name) {
			lower := strings.ToLower(word)
			if lower != searchable[0] {
				searchable = append(searchable, lower)
			}
		}

		// Determine icon
		icon := cfg.Icon
		if icon == "" {
			icon = "terminal"
		}

		// Determine subtitle
		subtitle := cfg.Category
		if subtitle == "" {
			subtitle = "Action"
		}

		items = append(items, SourceItem{
			ID:         actionID(cfg.Name),
			Title:      cfg.Name,
			Subtitle:   subtitle,
			Icon:       icon,
			Searchable: searchable,
			Action: Action{
				Type:    "exec",
				Command: cfg.Command,
			},
			Metadata: map[string]string{
				"command":  cfg.Command,
				"category": cfg.Category,
			},
		})
	}

	return items
}

func actionID(name string) string {
	// Create a stable ID from the action name
	slug := strings.ToLower(name)
	slug = strings.ReplaceAll(slug, " ", "-")
	return "action:" + slug
}
