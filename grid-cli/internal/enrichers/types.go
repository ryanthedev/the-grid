// Package enrichers provides terminal context enrichment for window management
package enrichers

import "strings"

// Enrichment represents what we learned about a window's context
type Enrichment struct {
	SSH  *SSHInfo  `json:"ssh,omitempty"`
	Tmux *TmuxInfo `json:"tmux,omitempty"`
}

// SSHInfo contains details about an SSH connection
type SSHInfo struct {
	User          string `json:"user"`
	Host          string `json:"host"`
	RemoteCwd     string `json:"remote_cwd,omitempty"`
	RemoteCommand string `json:"remote_command,omitempty"`
}

// TmuxInfo contains details about a tmux session
type TmuxInfo struct {
	SessionName  string   `json:"session_name"`
	WindowName   string   `json:"window_name"`
	PaneCommand  string   `json:"pane_command"`
	PaneCommands []string `json:"pane_commands,omitempty"`
}

// Enricher interface for enrichment implementations
type Enricher interface {
	Supports(bundleID string) bool
	Enrich(pid int, windowTitle string) *Enrichment
}

// Result is the formatted output from enrichment
type Result struct {
	Title          string `json:"title"`
	Subtitle       string `json:"subtitle"`
	StableIDSuffix string `json:"stable_id_suffix"`
}

// HasSSH returns true if SSH info is present
func (e *Enrichment) HasSSH() bool {
	return e != nil && e.SSH != nil
}

// HasTmux returns true if Tmux info is present
func (e *Enrichment) HasTmux() bool {
	return e != nil && e.Tmux != nil
}

// Merge combines another enrichment into this one
func (e *Enrichment) Merge(other *Enrichment) {
	if other == nil {
		return
	}
	if other.SSH != nil {
		e.SSH = other.SSH
	}
	if other.Tmux != nil {
		e.Tmux = other.Tmux
	}
}

// Format converts enrichment to display-ready Result
func (e *Enrichment) Format() *Result {
	if e == nil {
		return &Result{}
	}

	result := &Result{}

	sshOnly := e.HasSSH() && !e.HasTmux()
	tmuxOnly := !e.HasSSH() && e.HasTmux()
	sshAndTmux := e.HasSSH() && e.HasTmux()

	if sshOnly {
		result.Title = e.SSH.User + "@" + e.SSH.Host
		if e.SSH.RemoteCwd != "" && e.SSH.RemoteCommand != "" {
			result.Subtitle = e.SSH.RemoteCwd + ": " + e.SSH.RemoteCommand
		} else if e.SSH.RemoteCwd != "" {
			result.Subtitle = e.SSH.RemoteCwd
		} else if e.SSH.RemoteCommand != "" {
			result.Subtitle = e.SSH.RemoteCommand
		}
		result.StableIDSuffix = e.SSH.User + "@" + e.SSH.Host
	}

	if tmuxOnly {
		result.Title = e.Tmux.SessionName
		result.Subtitle = e.Tmux.SessionName + ":" + e.Tmux.WindowName
		if len(e.Tmux.PaneCommands) > 0 {
			result.Subtitle += " [" + strings.Join(e.Tmux.PaneCommands, " | ") + "]"
		} else if e.Tmux.PaneCommand != "" {
			result.Subtitle += " [" + e.Tmux.PaneCommand + "]"
		}
		result.StableIDSuffix = e.Tmux.SessionName + ":" + e.Tmux.WindowName
	}

	if sshAndTmux {
		result.Title = e.SSH.User + "@" + e.SSH.Host
		result.Subtitle = e.Tmux.SessionName + ":" + e.Tmux.WindowName
		if len(e.Tmux.PaneCommands) > 0 {
			result.Subtitle += " [" + strings.Join(e.Tmux.PaneCommands, " | ") + "]"
		} else if e.Tmux.PaneCommand != "" {
			result.Subtitle += " [" + e.Tmux.PaneCommand + "]"
		}
		result.StableIDSuffix = e.SSH.User + "@" + e.SSH.Host + "/" + e.Tmux.SessionName + ":" + e.Tmux.WindowName
	}

	return result
}
