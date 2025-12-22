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

func TestFindConfigFiles_MergeOrder(t *testing.T) {
	tmpDir := t.TempDir()

	// Create system config dirs
	systemDir1 := filepath.Join(tmpDir, "system1")
	systemDir2 := filepath.Join(tmpDir, "system2")
	userDir := filepath.Join(tmpDir, "user")

	// Create directory structure
	os.MkdirAll(filepath.Join(systemDir1, "testapp"), 0755)
	os.MkdirAll(filepath.Join(systemDir2, "testapp"), 0755)
	os.MkdirAll(filepath.Join(userDir, "testapp"), 0755)

	// Create config files
	file1 := filepath.Join(systemDir1, "testapp", "config.yaml")
	file2 := filepath.Join(systemDir2, "testapp", "config.yaml")
	userFile := filepath.Join(userDir, "testapp", "config.yaml")

	os.WriteFile(file1, []byte("system1"), 0644)
	os.WriteFile(file2, []byte("system2"), 0644)
	os.WriteFile(userFile, []byte("user"), 0644)

	// Set environment variables
	oldConfigDirs := os.Getenv("XDG_CONFIG_DIRS")
	oldConfigHome := os.Getenv("XDG_CONFIG_HOME")
	os.Setenv("XDG_CONFIG_DIRS", systemDir1+":"+systemDir2)
	os.Setenv("XDG_CONFIG_HOME", userDir)
	defer func() {
		if oldConfigDirs != "" {
			os.Setenv("XDG_CONFIG_DIRS", oldConfigDirs)
		} else {
			os.Unsetenv("XDG_CONFIG_DIRS")
		}
		if oldConfigHome != "" {
			os.Setenv("XDG_CONFIG_HOME", oldConfigHome)
		} else {
			os.Unsetenv("XDG_CONFIG_HOME")
		}
	}()

	// Test merge order: system dirs in reverse, then user
	got := FindConfigFiles("testapp", "config.yaml")
	want := []string{file2, file1, userFile}

	if len(got) != len(want) {
		t.Fatalf("FindConfigFiles() length = %d, want %d", len(got), len(want))
	}

	for i, path := range want {
		if got[i] != path {
			t.Errorf("FindConfigFiles()[%d] = %q, want %q", i, got[i], path)
		}
	}
}

func TestFindConfigFiles_SkipsMissingFiles(t *testing.T) {
	tmpDir := t.TempDir()

	// Create only user config dir with file
	userDir := filepath.Join(tmpDir, "user")
	os.MkdirAll(filepath.Join(userDir, "testapp"), 0755)
	userFile := filepath.Join(userDir, "testapp", "config.yaml")
	os.WriteFile(userFile, []byte("user"), 0644)

	// Create empty system dir (no config file)
	systemDir := filepath.Join(tmpDir, "system")
	os.MkdirAll(systemDir, 0755)

	// Set environment variables
	oldConfigDirs := os.Getenv("XDG_CONFIG_DIRS")
	oldConfigHome := os.Getenv("XDG_CONFIG_HOME")
	os.Setenv("XDG_CONFIG_DIRS", systemDir)
	os.Setenv("XDG_CONFIG_HOME", userDir)
	defer func() {
		if oldConfigDirs != "" {
			os.Setenv("XDG_CONFIG_DIRS", oldConfigDirs)
		} else {
			os.Unsetenv("XDG_CONFIG_DIRS")
		}
		if oldConfigHome != "" {
			os.Setenv("XDG_CONFIG_HOME", oldConfigHome)
		} else {
			os.Unsetenv("XDG_CONFIG_HOME")
		}
	}()

	// Should only return user file, silently skip missing system file
	got := FindConfigFiles("testapp", "config.yaml")
	want := []string{userFile}

	if len(got) != len(want) {
		t.Fatalf("FindConfigFiles() length = %d, want %d (got %v)", len(got), len(want), got)
	}

	if got[0] != want[0] {
		t.Errorf("FindConfigFiles()[0] = %q, want %q", got[0], want[0])
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
