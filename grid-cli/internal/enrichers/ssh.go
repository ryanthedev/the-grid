package enrichers

import (
	"os/exec"
	"os/user"
	"strconv"
	"strings"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/process"
)

// SSHEnricher detects SSH connections in terminal processes
type SSHEnricher struct {
	terminalBundleIDs map[string]bool
}

// NewSSHEnricher creates configured SSH enricher
func NewSSHEnricher() *SSHEnricher {
	return &SSHEnricher{
		terminalBundleIDs: map[string]bool{
			"com.mitchellh.ghostty": true,
		},
	}
}

// Supports returns true for terminal apps
func (e *SSHEnricher) Supports(bundleID string) bool {
	return e.terminalBundleIDs[bundleID]
}

// Enrich detects SSH and returns enrichment
func (e *SSHEnricher) Enrich(pid int, windowTitle string) *Enrichment {
	descendants, _ := process.GetDescendantPIDs(pid, 6)

	var sshPID int
	for _, dpid := range descendants {
		if isSSHProcess(dpid) {
			sshPID = dpid
			break
		}
	}
	if sshPID == 0 {
		return nil
	}

	args, err := getProcessArgs(sshPID)
	if err != nil {
		jsonlog.Log("ssh.args_err", jsonlog.WithMsg("failed to get args"))
		return nil
	}

	user, host, ok := parseSSHArgs(args)
	if !ok {
		jsonlog.Log("ssh.parse_err", jsonlog.WithMsg("failed to parse"), jsonlog.WithData(map[string]any{"args": args}))
		return nil
	}

	cwd, cmd := extractTitleContext(windowTitle)

	return &Enrichment{
		SSH: &SSHInfo{
			User:          user,
			Host:          host,
			RemoteCwd:     cwd,
			RemoteCommand: cmd,
		},
	}
}

// isSSHProcess checks if PID is an ssh process
func isSSHProcess(pid int) bool {
	cmd := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid))
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "ssh"
}

// getProcessArgs gets full command line
func getProcessArgs(pid int) (string, error) {
	cmd := exec.Command("ps", "-o", "args=", "-p", strconv.Itoa(pid))
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// parseSSHArgs extracts user and host from SSH command line
func parseSSHArgs(args string) (userResult, host string, ok bool) {
	parts := strings.Fields(args)
	if len(parts) < 2 {
		return "", "", false
	}

	flagsWithValues := map[string]bool{
		"-l": true, "-p": true, "-i": true, "-o": true,
		"-F": true, "-J": true, "-D": true, "-L": true,
		"-R": true, "-W": true, "-b": true, "-c": true,
		"-e": true, "-m": true, "-S": true, "-w": true,
	}

	var positionalArgs []string
	var extractedUser string

	for i := 1; i < len(parts); i++ {
		arg := parts[i]

		if arg == "-l" && i+1 < len(parts) {
			extractedUser = parts[i+1]
			i++
			continue
		}

		if flagsWithValues[arg] && i+1 < len(parts) {
			i++
			continue
		}

		if strings.HasPrefix(arg, "-") {
			continue
		}

		positionalArgs = append(positionalArgs, arg)
	}

	if len(positionalArgs) == 0 {
		return "", "", false
	}

	destination := positionalArgs[0]

	if at := strings.LastIndex(destination, "@"); at != -1 {
		userResult = destination[:at]
		host = destination[at+1:]
	} else {
		host = destination
		userResult = extractedUser
		if userResult == "" {
			if u, err := user.Current(); err == nil && u != nil {
				userResult = u.Username
			}
		}
	}

	return userResult, host, host != ""
}

// extractTitleContext parses window title for remote context
func extractTitleContext(title string) (cwd, command string) {
	if idx := strings.Index(title, ": "); idx != -1 {
		prefix := title[:idx]
		suffix := strings.TrimSpace(title[idx+2:])

		if strings.HasPrefix(prefix, "~") || strings.HasPrefix(prefix, "/") {
			cwd = prefix
			command = suffix
		} else if strings.HasPrefix(suffix, "~") || strings.HasPrefix(suffix, "/") {
			cwd = suffix
		} else {
			command = suffix
		}
	}

	return cwd, command
}
