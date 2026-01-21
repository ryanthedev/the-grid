package sources

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
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

	default:
		return fmt.Errorf("unknown action type: %s", action.Type)
	}
}
