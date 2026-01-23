package enrichers

import (
	"os/user"
	"testing"
)

func TestParseSSHArgs(t *testing.T) {
	currentUser := "defaultuser"
	if u, err := user.Current(); err == nil {
		currentUser = u.Username
	}

	tests := []struct {
		name     string
		args     string
		wantUser string
		wantHost string
		wantOK   bool
	}{
		{
			name:     "user@host format",
			args:     "ssh alice@server.com",
			wantUser: "alice",
			wantHost: "server.com",
			wantOK:   true,
		},
		{
			name:     "host only, defaults to current user",
			args:     "ssh server.com",
			wantUser: currentUser,
			wantHost: "server.com",
			wantOK:   true,
		},
		{
			name:     "with -l flag",
			args:     "ssh -l bob server.com",
			wantUser: "bob",
			wantHost: "server.com",
			wantOK:   true,
		},
		{
			name:     "with multiple flags",
			args:     "ssh -p 2222 -i ~/.ssh/key user@host.com",
			wantUser: "user",
			wantHost: "host.com",
			wantOK:   true,
		},
		{
			name:     "with remote command",
			args:     "ssh user@host.com ls -la",
			wantUser: "user",
			wantHost: "host.com",
			wantOK:   true,
		},
		{
			name:     "with jump host",
			args:     "ssh -J bastion user@target.com",
			wantUser: "user",
			wantHost: "target.com",
			wantOK:   true,
		},
		{
			name:     "empty args",
			args:     "ssh",
			wantUser: "",
			wantHost: "",
			wantOK:   false,
		},
		{
			name:     "only flags no host",
			args:     "ssh -v -A",
			wantUser: "",
			wantHost: "",
			wantOK:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotUser, gotHost, gotOK := parseSSHArgs(tt.args)
			if gotUser != tt.wantUser {
				t.Errorf("parseSSHArgs() user = %v, want %v", gotUser, tt.wantUser)
			}
			if gotHost != tt.wantHost {
				t.Errorf("parseSSHArgs() host = %v, want %v", gotHost, tt.wantHost)
			}
			if gotOK != tt.wantOK {
				t.Errorf("parseSSHArgs() ok = %v, want %v", gotOK, tt.wantOK)
			}
		})
	}
}

func TestExtractTitleContext(t *testing.T) {
	tests := []struct {
		name        string
		title       string
		wantCwd     string
		wantCommand string
	}{
		{
			name:        "path with command",
			title:       "~/code: vim file.txt",
			wantCwd:     "~/code",
			wantCommand: "vim file.txt",
		},
		{
			name:        "absolute path with command",
			title:       "/var/log: tail -f syslog",
			wantCwd:     "/var/log",
			wantCommand: "tail -f syslog",
		},
		{
			name:        "user@host with path suffix",
			title:       "root@server: ~/app",
			wantCwd:     "~/app",
			wantCommand: "",
		},
		{
			name:        "user@host with command suffix",
			title:       "root@server: htop",
			wantCwd:     "",
			wantCommand: "htop",
		},
		{
			name:        "no colon separator",
			title:       "server1",
			wantCwd:     "",
			wantCommand: "",
		},
		{
			name:        "empty title",
			title:       "",
			wantCwd:     "",
			wantCommand: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotCwd, gotCommand := extractTitleContext(tt.title)
			if gotCwd != tt.wantCwd {
				t.Errorf("extractTitleContext() cwd = %q, want %q", gotCwd, tt.wantCwd)
			}
			if gotCommand != tt.wantCommand {
				t.Errorf("extractTitleContext() command = %q, want %q", gotCommand, tt.wantCommand)
			}
		})
	}
}
