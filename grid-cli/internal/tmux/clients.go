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

// GetClients queries tmux for active client sessions.
// Returns a map keyed by ClientPID.
// Returns empty map (not error) if tmux is not running or no clients exist.
func GetClients() (map[int]TmuxClientInfo, error) {
	result := make(map[int]TmuxClientInfo)

	// Run tmux list-clients with format string
	cmd := exec.Command("tmux", "list-clients", "-F",
		"#{client_pid}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}")

	output, err := cmd.Output()
	if err != nil {
		// tmux not installed, no server running, or no clients
		// All are valid states - return empty map
		if exitErr, ok := err.(*exec.ExitError); ok {
			jsonlog.Log("tmux.noclient", jsonlog.WithData(map[string]any{
				"exit_code": exitErr.ExitCode(),
			}))
		}
		return result, nil
	}

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
