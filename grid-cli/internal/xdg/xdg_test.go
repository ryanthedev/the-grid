package xdg

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestConfigHome_Default(t *testing.T) {
	// Clear XDG_CONFIG_HOME to test default behavior
	old := os.Getenv("XDG_CONFIG_HOME")
	os.Unsetenv("XDG_CONFIG_HOME")
	defer func() {
		if old != "" {
			os.Setenv("XDG_CONFIG_HOME", old)
		}
	}()

	got := ConfigHome()
	home, _ := os.UserHomeDir()
	want := filepath.Join(home, ".config")

	if got != want {
		t.Errorf("ConfigHome() = %q, want %q", got, want)
	}
}

func TestConfigHome_Custom(t *testing.T) {
	old := os.Getenv("XDG_CONFIG_HOME")
	custom := "/custom/config"
	os.Setenv("XDG_CONFIG_HOME", custom)
	defer func() {
		if old != "" {
			os.Setenv("XDG_CONFIG_HOME", old)
		} else {
			os.Unsetenv("XDG_CONFIG_HOME")
		}
	}()

	got := ConfigHome()
	if got != custom {
		t.Errorf("ConfigHome() = %q, want %q", got, custom)
	}
}

func TestConfigDirs_FiltersRelativePaths(t *testing.T) {
	old := os.Getenv("XDG_CONFIG_DIRS")
	os.Setenv("XDG_CONFIG_DIRS", "/valid/path:relative/path::/another/valid:also/relative")
	defer func() {
		if old != "" {
			os.Setenv("XDG_CONFIG_DIRS", old)
		} else {
			os.Unsetenv("XDG_CONFIG_DIRS")
		}
	}()

	got := ConfigDirs()
	want := []string{"/valid/path", "/another/valid"}

	if len(got) != len(want) {
		t.Fatalf("ConfigDirs() length = %d, want %d", len(got), len(want))
	}

	for i, path := range want {
		if got[i] != path {
			t.Errorf("ConfigDirs()[%d] = %q, want %q", i, got[i], path)
		}
	}
}

func TestConfigDirs_Default(t *testing.T) {
	// Clear XDG_CONFIG_DIRS to test default behavior
	old := os.Getenv("XDG_CONFIG_DIRS")
	os.Unsetenv("XDG_CONFIG_DIRS")
	defer func() {
		if old != "" {
			os.Setenv("XDG_CONFIG_DIRS", old)
		}
	}()

	got := ConfigDirs()

	// All platforms should have /etc/xdg as first entry
	if len(got) == 0 || got[0] != "/etc/xdg" {
		t.Errorf("ConfigDirs()[0] = %q, want %q", got[0], "/etc/xdg")
	}

	// macOS should have additional paths
	if runtime.GOOS == "darwin" {
		if len(got) < 3 {
			t.Errorf("ConfigDirs() on darwin should have at least 3 entries, got %d", len(got))
		}
		expectedPaths := []string{"/etc/xdg", "/opt/homebrew/etc", "/usr/local/etc"}
		for i, want := range expectedPaths {
			if i >= len(got) || got[i] != want {
				t.Errorf("ConfigDirs()[%d] = %q, want %q", i, got[i], want)
			}
		}
	}
}

func TestStateHome_Default(t *testing.T) {
	// Clear XDG_STATE_HOME to test default behavior
	old := os.Getenv("XDG_STATE_HOME")
	os.Unsetenv("XDG_STATE_HOME")
	defer func() {
		if old != "" {
			os.Setenv("XDG_STATE_HOME", old)
		}
	}()

	got := StateHome()
	home, _ := os.UserHomeDir()
	want := filepath.Join(home, ".local", "state")

	if got != want {
		t.Errorf("StateHome() = %q, want %q", got, want)
	}
}

func TestDedup(t *testing.T) {
	tests := []struct {
		name  string
		input []string
		want  []string
	}{
		{
			name:  "no duplicates",
			input: []string{"/a", "/b", "/c"},
			want:  []string{"/a", "/b", "/c"},
		},
		{
			name:  "with duplicates",
			input: []string{"/a", "/b", "/a", "/c", "/b"},
			want:  []string{"/a", "/b", "/c"},
		},
		{
			name:  "empty slice",
			input: []string{},
			want:  []string{},
		},
		{
			name:  "all same",
			input: []string{"/a", "/a", "/a"},
			want:  []string{"/a"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := dedup(tt.input)
			if len(got) != len(tt.want) {
				t.Fatalf("dedup() length = %d, want %d", len(got), len(tt.want))
			}
			for i, path := range tt.want {
				if got[i] != path {
					t.Errorf("dedup()[%d] = %q, want %q", i, got[i], path)
				}
			}
		})
	}
}
