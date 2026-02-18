package sources

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/tmux"
)

// cleanEnv returns the current environment with tmux-related variables removed.
// This prevents spawned apps from inheriting the tmux session.
func cleanEnv() []string {
	var clean []string
	for _, env := range os.Environ() {
		key := strings.SplitN(env, "=", 2)[0]
		switch key {
		case "TMUX", "TMUX_PANE", "TMUX_PLUGIN_MANAGER_PATH":
			continue
		default:
			clean = append(clean, env)
		}
	}
	return clean
}

// ExecuteAction performs the action associated with a selected item.
// The client parameter is optional - only needed for focus-window actions.
// It accepts interface{} to avoid circular imports with the client package.
func ExecuteAction(ctx context.Context, action Action) error {
	switch action.Type {
	case "focus-window":
		// Window focus is handled separately by the caller since it needs
		// access to the RPC client. This case is here for completeness.
		return fmt.Errorf("focus-window actions should be handled by caller")

	case "open-app":
		// open -na "/Applications/Slack.app" (new instance)
		if action.AppPath == "" {
			return fmt.Errorf("open-app action missing appPath")
		}
		jsonlog.Log("exec.open-app", jsonlog.WithData(map[string]any{
			"path": action.AppPath,
		}))
		cmd := exec.CommandContext(ctx, "open", "-na", action.AppPath)
		cmd.Env = cleanEnv()
		return cmd.Run()

	case "open-chrome-profile":
		// open -na "Google Chrome" --args --profile-directory="Profile 1"
		if action.ProfileDir == "" {
			return fmt.Errorf("open-chrome-profile action missing profileDir")
		}
		jsonlog.Log("exec.chrome-profile", jsonlog.WithData(map[string]any{
			"profile": action.ProfileDir,
		}))
		cmd := exec.CommandContext(ctx, "open", "-na", "Google Chrome", "--args",
			"--profile-directory="+action.ProfileDir)
		cmd.Env = cleanEnv()
		return cmd.Run()

	case "exec":
		// Custom action - run via shell
		if action.Command == "" {
			return fmt.Errorf("exec action missing command")
		}
		jsonlog.Log("exec.custom", jsonlog.WithData(map[string]any{
			"cmd": action.Command,
		}))
		cmd := exec.CommandContext(ctx, "sh", "-c", action.Command)
		cmd.Env = cleanEnv()
		return cmd.Run()

	case "open-dir":
		// Open directory in tmux session (like the t command)
		if action.DirPath == "" {
			return fmt.Errorf("open-dir action missing dirPath")
		}
		return openDirInTmux(ctx, action.DirPath)

	default:
		return fmt.Errorf("unknown action type: %s", action.Type)
	}
}

// openDirInTmux creates or switches to a tmux session for the given directory.
// Opens a new Ghostty window with the tmux session attached.
func openDirInTmux(ctx context.Context, dirPath string) error {
	// Derive session name from directory name
	sessionName := filepath.Base(dirPath)
	// Sanitize: tmux doesn't like dots or colons in session names
	sessionName = strings.ReplaceAll(sessionName, ".", "_")
	sessionName = strings.ReplaceAll(sessionName, ":", "_")

	jsonlog.Log("exec.open-dir", jsonlog.WithData(map[string]any{
		"path":    dirPath,
		"session": sessionName,
	}))

	// Boost frecency in zoxide
	if zoxidePath, err := findZoxideBinary(""); err == nil {
		_ = exec.CommandContext(ctx, zoxidePath, "add", dirPath).Run()
	}

	// Resolve tmux binary (checks common paths like /opt/homebrew/bin)
	tmuxPath := tmux.FindTmux()

	// Check if session already exists
	hasSession := exec.CommandContext(ctx, tmuxPath, "has-session", "-t", sessionName)
	sessionExists := hasSession.Run() == nil

	if !sessionExists {
		// Create new detached session
		newSession := exec.CommandContext(ctx, tmuxPath, "new-session", "-d", "-s", sessionName, "-c", dirPath)
		if err := newSession.Run(); err != nil {
			return fmt.Errorf("failed to create tmux session: %w", err)
		}
	}

	// Open new Ghostty window with tmux attach
	cmd := exec.CommandContext(ctx, "open", "-na", "Ghostty", "--args", "-e", tmuxPath, "attach", "-t", sessionName)
	cmd.Env = cleanEnv()
	return cmd.Run()
}
