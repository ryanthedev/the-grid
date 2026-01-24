package enrichers

import "testing"

func TestEnrichment_HasSSH(t *testing.T) {
	tests := []struct {
		name string
		e    *Enrichment
		want bool
	}{
		{"nil enrichment", nil, false},
		{"no ssh", &Enrichment{}, false},
		{"has ssh", &Enrichment{SSH: &SSHInfo{User: "user", Host: "host"}}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.e.HasSSH(); got != tt.want {
				t.Errorf("HasSSH() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestEnrichment_Merge(t *testing.T) {
	e := &Enrichment{}
	other := &Enrichment{
		SSH:  &SSHInfo{User: "user", Host: "host"},
		Tmux: &TmuxInfo{SessionName: "session", WindowName: "window", PaneCommand: "vim"},
	}
	e.Merge(other)
	if !e.HasSSH() || !e.HasTmux() {
		t.Error("Merge failed to copy SSH and Tmux")
	}
}

func TestEnrichment_Format_SSHOnly(t *testing.T) {
	e := &Enrichment{
		SSH: &SSHInfo{
			User:          "user",
			Host:          "example.com",
			RemoteCwd:     "/home/user",
			RemoteCommand: "vim file.txt",
		},
	}
	r := e.Format()
	if r.Title != "user@example.com" {
		t.Errorf("Title = %q, want %q", r.Title, "user@example.com")
	}
	if r.Subtitle != "/home/user: vim file.txt" {
		t.Errorf("Subtitle = %q, want %q", r.Subtitle, "/home/user: vim file.txt")
	}
}

func TestEnrichment_Format_TmuxOnly(t *testing.T) {
	e := &Enrichment{
		Tmux: &TmuxInfo{
			SessionName: "dev",
			WindowName:  "editor",
			PaneCommand: "vim",
		},
	}
	r := e.Format()
	if r.Title != "dev" {
		t.Errorf("Title = %q, want %q", r.Title, "dev")
	}
	if r.Subtitle != "dev:editor [vim]" {
		t.Errorf("Subtitle = %q, want %q", r.Subtitle, "dev:editor [vim]")
	}
}

func TestEnrichment_Format_SSHAndTmux(t *testing.T) {
	e := &Enrichment{
		SSH: &SSHInfo{
			User: "user",
			Host: "example.com",
		},
		Tmux: &TmuxInfo{
			SessionName: "dev",
			WindowName:  "editor",
			PaneCommand: "vim",
		},
	}
	r := e.Format()
	if r.Title != "user@example.com" {
		t.Errorf("Title = %q, want %q", r.Title, "user@example.com")
	}
	if r.Subtitle != "dev:editor [vim]" {
		t.Errorf("Subtitle = %q, want %q", r.Subtitle, "dev:editor [vim]")
	}
	want := "user@example.com/dev:editor"
	if r.StableIDSuffix != want {
		t.Errorf("StableIDSuffix = %q, want %q", r.StableIDSuffix, want)
	}
}

func TestEnrichment_Format_TmuxWithSessionWindows(t *testing.T) {
	e := &Enrichment{
		Tmux: &TmuxInfo{
			SessionName:    "dev",
			WindowName:     "editor",
			SessionWindows: []string{"editor", "shell", "logs"},
		},
	}
	r := e.Format()
	if r.Subtitle != "dev:editor [editor | shell | logs]" {
		t.Errorf("Subtitle = %q, want %q", r.Subtitle, "dev:editor [editor | shell | logs]")
	}
}

func TestEnrichment_Merge_Nil(t *testing.T) {
	e := &Enrichment{SSH: &SSHInfo{User: "user", Host: "host"}}
	e.Merge(nil)
	if !e.HasSSH() {
		t.Error("Merge(nil) should preserve existing SSH")
	}
}
