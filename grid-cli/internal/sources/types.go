// Package sources provides unified item discovery for the launcher
package sources

// SourceItem represents a unified item from any source
type SourceItem struct {
	ID         string            `json:"id"`
	Title      string            `json:"title"`
	Subtitle   string            `json:"subtitle,omitempty"`
	Preview    string            `json:"preview,omitempty"`
	Icon       string            `json:"icon,omitempty"`
	Searchable []string          `json:"searchable"`
	Action     Action            `json:"action"`
	Metadata   map[string]string `json:"metadata,omitempty"`
}

// Action describes what happens when an item is selected
type Action struct {
	Type       string `json:"type"`
	WindowID   int    `json:"windowId,omitempty"`
	AppPath    string `json:"appPath,omitempty"`
	Command    string `json:"command,omitempty"`
	ProfileDir string `json:"profileDir,omitempty"`
}

// ActionConfig defines a custom action from config
type ActionConfig struct {
	Name     string
	Command  string
	Category string
	Icon     string
}
