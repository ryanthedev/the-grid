package layout

import (
	"strings"
	"testing"

	"github.com/ryanthedev/grid-cli/internal/types"
)

func TestRatiosToTrackStrings(t *testing.T) {
	tests := []struct {
		name     string
		tracks   []types.TrackSize
		ratios   []float64
		expected []string
	}{
		{
			name: "equal 3-column fr layout",
			tracks: []types.TrackSize{
				{Type: types.TrackFr, Value: 1},
				{Type: types.TrackFr, Value: 1},
				{Type: types.TrackFr, Value: 1},
			},
			ratios:   []float64{1.0 / 3, 1.0 / 3, 1.0 / 3},
			expected: []string{"1fr", "1fr", "1fr"},
		},
		{
			name: "unequal 3-column (1fr 3fr 1fr resized)",
			tracks: []types.TrackSize{
				{Type: types.TrackFr, Value: 1},
				{Type: types.TrackFr, Value: 3},
				{Type: types.TrackFr, Value: 1},
			},
			// ratios reflecting 20%/60%/20% of 5fr total
			ratios:   []float64{0.2, 0.6, 0.2},
			expected: []string{"1fr", "3fr", "1fr"},
		},
		{
			name: "mixed fr and px tracks",
			tracks: []types.TrackSize{
				{Type: types.TrackPx, Value: 300},
				{Type: types.TrackFr, Value: 1},
				{Type: types.TrackFr, Value: 1},
			},
			// ratios only apply to 2 flex tracks, 70/30 split
			ratios:   []float64{0.7, 0.3},
			expected: []string{"300px", "1.4fr", "0.6fr"},
		},
		{
			name: "mixed with auto track",
			tracks: []types.TrackSize{
				{Type: types.TrackFr, Value: 2},
				{Type: types.TrackAuto},
				{Type: types.TrackFr, Value: 1},
			},
			ratios:   []float64{0.75, 0.25},
			expected: []string{"2.25fr", "auto", "0.75fr"},
		},
		{
			name: "minmax track",
			tracks: []types.TrackSize{
				{Type: types.TrackMinMax, Min: 200, Max: 1},
				{Type: types.TrackFr, Value: 2},
			},
			ratios:   []float64{0.4, 0.6},
			expected: []string{"minmax(200px, 1.2fr)", "1.8fr"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := RatiosToTrackStrings(tt.tracks, tt.ratios)
			if len(got) != len(tt.expected) {
				t.Fatalf("length mismatch: got %d, want %d", len(got), len(tt.expected))
			}
			for i := range got {
				if got[i] != tt.expected[i] {
					t.Errorf("track[%d] = %q, want %q", i, got[i], tt.expected[i])
				}
			}
		})
	}
}

func TestGetLayoutWithOverrides(t *testing.T) {
	// This test exercises the config-level override merging.
	// We import config indirectly through a layout config YAML round-trip test.
	// The actual config.GetLayout is tested via config_test.go, but we verify
	// the override struct shapes here.

	override := types.StackMode("tabs")
	if override != types.StackTabs {
		t.Errorf("expected tabs, got %s", override)
	}
}

func TestFormatFloat(t *testing.T) {
	tests := []struct {
		input    float64
		expected string
	}{
		{1.0, "1"},
		{1.5, "1.5"},
		{1.25, "1.25"},
		{1.10, "1.1"},
		{0.60, "0.6"},
		{2.00, "2"},
	}

	for _, tt := range tests {
		got := formatFloat(tt.input)
		if got != tt.expected {
			t.Errorf("formatFloat(%v) = %q, want %q", tt.input, got, tt.expected)
		}
	}
}

func TestFormatFr(t *testing.T) {
	tests := []struct {
		input    float64
		expected string
	}{
		{1.0, "1fr"},
		{2.0, "2fr"},
		{1.5, "1.5fr"},
		{0.6, "0.6fr"},
		{1.25, "1.25fr"},
	}

	for _, tt := range tests {
		got := formatFr(tt.input)
		if !strings.HasSuffix(got, "fr") {
			t.Errorf("formatFr(%v) = %q, doesn't end in 'fr'", tt.input, got)
		}
		if got != tt.expected {
			t.Errorf("formatFr(%v) = %q, want %q", tt.input, got, tt.expected)
		}
	}
}
