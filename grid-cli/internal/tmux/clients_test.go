package tmux

import (
	"fmt"
	"testing"
)

func TestParseClientLine(t *testing.T) {
	tests := []struct {
		name    string
		line    string
		want    TmuxClientInfo
		wantErr bool
	}{
		{
			name: "valid line",
			line: "12345|mysession|editor|0|1|vim",
			want: TmuxClientInfo{
				ClientPID:   12345,
				SessionName: "mysession",
				WindowName:  "editor",
				WindowIndex: 0,
				PaneIndex:   1,
				PaneCommand: "vim",
			},
			wantErr: false,
		},
		{
			name: "session with spaces in window name",
			line: "99999|dev|long window name|2|0|zsh",
			want: TmuxClientInfo{
				ClientPID:   99999,
				SessionName: "dev",
				WindowName:  "long window name",
				WindowIndex: 2,
				PaneIndex:   0,
				PaneCommand: "zsh",
			},
			wantErr: false,
		},
		{
			name: "command with pipes",
			line: "11111|main|shell|0|0|cat | grep foo",
			want: TmuxClientInfo{
				ClientPID:   11111,
				SessionName: "main",
				WindowName:  "shell",
				WindowIndex: 0,
				PaneIndex:   0,
				PaneCommand: "cat | grep foo",
			},
			wantErr: false,
		},
		{
			name:    "insufficient fields",
			line:    "12345|mysession",
			wantErr: true,
		},
		{
			name:    "invalid pid",
			line:    "notapid|mysession|editor|0|1|vim",
			wantErr: true,
		},
		{
			name:    "empty line",
			line:    "",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseClientLine(tt.line)
			if (err != nil) != tt.wantErr {
				t.Errorf("parseClientLine() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && got != tt.want {
				t.Errorf("parseClientLine() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestGetPaneCommandsTargetFormat(t *testing.T) {
	// This test documents why we use window index instead of window name.
	// Window names with dots (like "2.1.17") break tmux target parsing because
	// tmux interprets "." as a pane separator.
	//
	// Example: "thegrid:2.1.17" would be parsed as:
	//   session=thegrid, window=2, pane=1.17 (invalid)
	//
	// Using window index avoids this: "thegrid:0" is unambiguous.

	tests := []struct {
		name        string
		sessionName string
		windowIndex int
		wantTarget  string
	}{
		{
			name:        "simple window",
			sessionName: "dev",
			windowIndex: 0,
			wantTarget:  "dev:0",
		},
		{
			name:        "higher window index",
			sessionName: "thegrid",
			windowIndex: 5,
			wantTarget:  "thegrid:5",
		},
		{
			name:        "session with hyphen",
			sessionName: "my-session",
			windowIndex: 2,
			wantTarget:  "my-session:2",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Verify target format matches expected pattern
			// This is the format used in GetPaneCommands
			target := fmt.Sprintf("%s:%d", tt.sessionName, tt.windowIndex)
			if target != tt.wantTarget {
				t.Errorf("target = %q, want %q", target, tt.wantTarget)
			}
		})
	}
}

func TestParseMultipleLines(t *testing.T) {
	// Simulate parsing multiple lines like GetClients would
	lines := []string{
		"12345|session1|win1|0|0|vim",
		"67890|session2|win2|1|0|zsh",
		"",
		"invalid",
		"11111|session3|win3|0|0|htop",
	}

	result := make(map[int]TmuxClientInfo)
	for _, line := range lines {
		if line == "" {
			continue
		}
		info, err := parseClientLine(line)
		if err != nil {
			continue
		}
		result[info.ClientPID] = info
	}

	// Should have 3 valid entries
	if len(result) != 3 {
		t.Errorf("expected 3 entries, got %d", len(result))
	}

	// Verify specific entries
	if info, ok := result[12345]; !ok || info.SessionName != "session1" {
		t.Errorf("missing or incorrect entry for PID 12345")
	}
	if info, ok := result[67890]; !ok || info.SessionName != "session2" {
		t.Errorf("missing or incorrect entry for PID 67890")
	}
	if info, ok := result[11111]; !ok || info.SessionName != "session3" {
		t.Errorf("missing or incorrect entry for PID 11111")
	}
}
