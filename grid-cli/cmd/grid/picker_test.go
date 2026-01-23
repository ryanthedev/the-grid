package main

import (
	"testing"

	"github.com/ryanthedev/grid-cli/internal/enrichers"
)

func TestStableWindowIDTmux(t *testing.T) {
	// Test 1: Tmux window ID format using enrichers.Result
	enrichResult := &enrichers.Result{
		Title:          "dev",
		Subtitle:       "dev:nvim",
		StableIDSuffix: "dev:nvim",
	}
	id := stableWindowID(123, enrichResult, "com.example.terminal", "Terminal", 456)
	expected := "tmux:dev:nvim"
	if id != expected {
		t.Errorf("expected %q, got %q", expected, id)
	}
}

func TestStableWindowIDNonTmux(t *testing.T) {
	// Test 2: Non-tmux window ID format
	id := stableWindowID(123, nil, "com.apple.Safari", "GitHub", 456)

	// Should match pattern: com.apple.Safari:github:XXXX
	if len(id) < 20 {
		t.Errorf("expected longer ID, got %q", id)
	}
	if id[:17] != "com.apple.Safari:" {
		t.Errorf("expected to start with 'com.apple.Safari:', got %q", id)
	}
	// Should contain normalized title
	if id[17:23] != "github" {
		t.Errorf("expected normalized title 'github' at position 17, got %q", id[17:23])
	}
}

func TestStableWindowIDEmptyTitle(t *testing.T) {
	// Test 3: Empty title fallback
	id := stableWindowID(123, nil, "com.apple.Safari", "", 456)
	expected := "com.apple.Safari:untitled:123"
	if id != expected {
		t.Errorf("expected %q, got %q", expected, id)
	}
}

func TestStableWindowIDNilTmuxInfo(t *testing.T) {
	// Test 4: Nil tmuxInfo no panic
	id := stableWindowID(123, nil, "com.example.app", "Window Title", 456)
	if id == "" {
		t.Error("expected non-empty ID")
	}
	// Should be bundle-based since tmuxInfo is nil
	if id[:16] != "com.example.app:" {
		t.Errorf("expected to start with 'com.example.app:', got %q", id)
	}
}

func TestSimilarTitlesNoCollision(t *testing.T) {
	// Test 7: Similar titles should produce different stable IDs due to hash
	id1 := stableWindowID(1, nil, "com.apple.Safari", "GitHub - Repo A", 100)
	id2 := stableWindowID(2, nil, "com.apple.Safari", "GitHub - Repo B", 101)

	if id1 == id2 {
		t.Errorf("expected different IDs for different titles, got same: %q", id1)
	}
}

func TestNormalizeTitle(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"GitHub - Anthropics", "github-anthropics"},
		{"UPPERCASE", "uppercase"},
		{"with spaces", "with-spaces"},
		{"special!@#$chars", "special-chars"},
		{"multiple   spaces", "multiple-spaces"},
		{"", ""},
		{"a-very-long-title-that-exceeds-thirty-characters-limit", "a-very-long-title-that-exceeds"},
	}

	for _, tc := range tests {
		result := normalizeTitle(tc.input)
		if result != tc.expected {
			t.Errorf("normalizeTitle(%q) = %q, expected %q", tc.input, result, tc.expected)
		}
	}
}

func TestHash4(t *testing.T) {
	// Should return exactly 4 hex chars
	h := hash4("test")
	if len(h) != 4 {
		t.Errorf("expected 4 chars, got %d: %q", len(h), h)
	}

	// Same input should produce same output
	h2 := hash4("test")
	if h != h2 {
		t.Errorf("expected same hash for same input: %q vs %q", h, h2)
	}

	// Different input should (almost certainly) produce different output
	h3 := hash4("different")
	if h == h3 {
		t.Error("expected different hash for different input")
	}
}
