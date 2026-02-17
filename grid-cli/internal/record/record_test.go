package record

import (
	"testing"

	"github.com/ryanthedev/grid-cli/internal/types"
)

func TestParseTarget(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    Target
		wantErr bool
	}{
		{"empty args = cell", nil, Target{Type: TargetCell}, false},
		{"cell", []string{"cell"}, Target{Type: TargetCell}, false},
		{"cell with id", []string{"cell", "A"}, Target{Type: TargetCell, ID: "A"}, false},
		{"window", []string{"window"}, Target{Type: TargetWindow}, false},
		{"window with id", []string{"window", "123"}, Target{Type: TargetWindow, ID: "123"}, false},
		{"screen", []string{"screen"}, Target{Type: TargetScreen}, false},
		{"screen with number", []string{"screen", "2"}, Target{Type: TargetScreen, ID: "2"}, false},
		{"all", []string{"all"}, Target{Type: TargetAll}, false},
		{"unknown", []string{"bogus"}, Target{}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseTarget(tt.args)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseTarget() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && (got.Type != tt.want.Type || got.ID != tt.want.ID) {
				t.Errorf("ParseTarget() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestGenerateOutputPath(t *testing.T) {
	path := GenerateOutputPath("", "cell-A", "gif")
	if path == "" {
		t.Fatal("expected non-empty path")
	}
	if len(path) < len("recording-cell-A-.gif") {
		t.Errorf("path too short: %s", path)
	}
	if !contains(path, "cell-A") {
		t.Errorf("path missing label: %s", path)
	}
	if !contains(path, ".gif") {
		t.Errorf("path missing format extension: %s", path)
	}

	mp4 := GenerateOutputPath("", "window-123", "mp4")
	if !contains(mp4, ".mp4") {
		t.Errorf("mp4 path missing extension: %s", mp4)
	}

	// With output directory
	withDir := GenerateOutputPath("/tmp/recordings", "cell-A", "gif")
	if !contains(withDir, "/tmp/recordings/") {
		t.Errorf("path missing dir prefix: %s", withDir)
	}
	if !contains(withDir, "cell-A") {
		t.Errorf("path missing label: %s", withDir)
	}
}

func TestBuildCaptureArgs(t *testing.T) {
	region := types.Rect{X: 100, Y: 200, Width: 800, Height: 600}

	args := BuildCaptureArgs(region, 5, false, "/tmp/out.mov")
	expected := []string{"-v", "-V", "5", "-R", "100,200,800,600", "/tmp/out.mov"}
	if !sliceEqual(args, expected) {
		t.Errorf("BuildCaptureArgs(no cursor) = %v, want %v", args, expected)
	}

	args = BuildCaptureArgs(region, 10, true, "/tmp/out.mov")
	expected = []string{"-v", "-V", "10", "-C", "-R", "100,200,800,600", "/tmp/out.mov"}
	if !sliceEqual(args, expected) {
		t.Errorf("BuildCaptureArgs(with cursor) = %v, want %v", args, expected)
	}
}

func TestQualityPresets(t *testing.T) {
	tests := []struct {
		quality QualityLevel
		mp4CRF  int
		webmCRF int
	}{
		{QualityLow, 28, 40},
		{QualityMedium, 23, 31},
		{QualityHigh, 18, 24},
	}

	for _, tt := range tests {
		t.Run(string(tt.quality), func(t *testing.T) {
			if got := mp4CRF(tt.quality); got != tt.mp4CRF {
				t.Errorf("mp4CRF(%s) = %d, want %d", tt.quality, got, tt.mp4CRF)
			}
			if got := webmCRF(tt.quality); got != tt.webmCRF {
				t.Errorf("webmCRF(%s) = %d, want %d", tt.quality, got, tt.webmCRF)
			}
		})
	}
}

func TestEffectiveFPS(t *testing.T) {
	o := Options{Format: "gif", FPS: 0}
	if got := o.EffectiveFPS(); got != 10 {
		t.Errorf("gif default FPS = %d, want 10", got)
	}

	o = Options{Format: "mp4", FPS: 0}
	if got := o.EffectiveFPS(); got != 30 {
		t.Errorf("mp4 default FPS = %d, want 30", got)
	}

	o = Options{Format: "gif", FPS: 15}
	if got := o.EffectiveFPS(); got != 15 {
		t.Errorf("explicit FPS = %d, want 15", got)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchString(s, substr)
}

func searchString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func sliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
