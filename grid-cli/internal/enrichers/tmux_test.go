package enrichers

import (
	"testing"

	"github.com/ryanthedev/grid-cli/internal/tmux"
)

func TestTmuxEnricher_Supports(t *testing.T) {
	e := NewTmuxEnricher()
	tests := []struct {
		bundleID string
		want     bool
	}{
		{"com.mitchellh.ghostty", true},
		{"com.googlecode.iterm2", true},
		{"com.apple.Safari", false},
		{"", false},
	}
	for _, tt := range tests {
		t.Run(tt.bundleID, func(t *testing.T) {
			if got := e.Supports(tt.bundleID); got != tt.want {
				t.Errorf("Supports(%q) = %v, want %v", tt.bundleID, got, tt.want)
			}
		})
	}
}

func TestTmuxEnricher_buildEnrichment(t *testing.T) {
	e := NewTmuxEnricher()

	info := &tmux.TmuxClientInfo{
		ClientPID:   1234,
		SessionName: "dev",
		WindowName:  "editor",
		PaneCommand: "nvim",
	}

	result := e.buildEnrichment(info)

	if result == nil {
		t.Fatal("buildEnrichment returned nil")
	}
	if result.Tmux == nil {
		t.Fatal("buildEnrichment returned nil Tmux")
	}
	if result.Tmux.SessionName != "dev" {
		t.Errorf("SessionName = %q, want %q", result.Tmux.SessionName, "dev")
	}
	if result.Tmux.WindowName != "editor" {
		t.Errorf("WindowName = %q, want %q", result.Tmux.WindowName, "editor")
	}
	if result.Tmux.PaneCommand != "nvim" {
		t.Errorf("PaneCommand = %q, want %q", result.Tmux.PaneCommand, "nvim")
	}
}

func TestTmuxEnricher_Enrich_NoTmux(t *testing.T) {
	e := NewTmuxEnricher()

	// With no tmux running, Enrich should return nil gracefully
	result := e.Enrich(99999, "some title")
	if result != nil {
		t.Errorf("Enrich with invalid PID should return nil, got %+v", result)
	}
}
