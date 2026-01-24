// Package tmux provides utilities for querying tmux session information
package tmux

import (
	"os/exec"
	"strconv"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// TmuxClientInfo holds information about a tmux client attachment
type TmuxClientInfo struct {
	ClientPID   int
	SessionName string
	WindowName  string
	WindowIndex int
	PaneIndex   int
	PaneCommand string
}

// tmuxPaths lists common tmux installation locations to check when tmux
// is not in PATH (e.g., when launched from GUI app with minimal PATH)
var tmuxPaths = []string{
	"tmux", // Try PATH first
	"/opt/homebrew/bin/tmux",
	"/usr/local/bin/tmux",
	"/usr/bin/tmux",
}

// findTmux returns the path to tmux binary, checking common locations
// if not found in PATH
func findTmux() string {
	for _, p := range tmuxPaths {
		if path, err := exec.LookPath(p); err == nil {
			return path
		}
	}
	return "tmux" // fallback, will fail with clear error
}

// GetClients queries tmux for active client sessions.
// Returns a map keyed by ClientPID.
// Returns empty map (not error) if tmux is not running or no clients exist.
func GetClients() (map[int]TmuxClientInfo, error) {
	result := make(map[int]TmuxClientInfo)

	// Find tmux binary, checking common locations if not in PATH
	tmuxPath := findTmux()

	// Run tmux list-clients with format string
	cmd := exec.Command(tmuxPath, "list-clients", "-F",
		"#{client_pid}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}")

	output, err := cmd.Output()
	if err != nil {
		// tmux not installed, no server running, or no clients
		// All are valid states - return empty map
		if exitErr, ok := err.(*exec.ExitError); ok {
			jsonlog.Log("tmux.noclient", jsonlog.WithData(map[string]any{
				"exit_code": exitErr.ExitCode(),
			}))
		} else {
			// exec.ErrNotFound, permission errors, etc.
			jsonlog.Log("tmux.exec_err", jsonlog.WithMsg(err.Error()))
		}
		return result, nil
	}

	// Log successful client query for diagnostics
	jsonlog.Log("tmux.clients", jsonlog.WithData(map[string]any{
		"count": len(strings.Split(strings.TrimSpace(string(output)), "\n")),
	}))

	// Parse output line by line
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}

		info, err := parseClientLine(line)
		if err != nil {
			jsonlog.Log("tmux.parse_err", jsonlog.WithMsg("skipping malformed line"),
				jsonlog.WithData(map[string]any{"line": line}))
			continue
		}

		result[info.ClientPID] = info
	}

	return result, nil
}

// parseClientLine parses a single line of tmux list-clients output.
// Expected format: pid|session|window|window_idx|pane_idx|command
func parseClientLine(line string) (TmuxClientInfo, error) {
	parts := strings.SplitN(line, "|", 6)
	if len(parts) < 6 {
		return TmuxClientInfo{}, &parseError{"insufficient fields"}
	}

	clientPID, err := strconv.Atoi(parts[0])
	if err != nil {
		return TmuxClientInfo{}, &parseError{"invalid client_pid"}
	}

	windowIndex, err := strconv.Atoi(parts[3])
	if err != nil {
		windowIndex = 0
	}

	paneIndex, err := strconv.Atoi(parts[4])
	if err != nil {
		paneIndex = 0
	}

	return TmuxClientInfo{
		ClientPID:   clientPID,
		SessionName: parts[1],
		WindowName:  parts[2],
		WindowIndex: windowIndex,
		PaneIndex:   paneIndex,
		PaneCommand: parts[5],
	}, nil
}

type parseError struct {
	msg string
}

func (e *parseError) Error() string {
	return "tmux parse: " + e.msg
}

// GetSessionWindowNames returns all window names for a tmux session.
// Returns empty slice (not error) if tmux is not running or session doesn't exist.
func GetSessionWindowNames(sessionName string) []string {
	tmuxPath := findTmux()
	cmd := exec.Command(tmuxPath, "list-windows", "-t", sessionName, "-F", "#{window_name}")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var commands []string
	for _, line := range lines {
		if line = strings.TrimSpace(line); line != "" {
			commands = append(commands, line)
		}
	}
	return commands
}
