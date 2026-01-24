package enrichers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sync"
)

// Supported Chromium-based browsers
// Note: Only Chrome is currently supported because loadLocalState() reads Chrome's
// Local State path. Other browsers use different paths (Brave, Edge, Canary, etc.)
// TODO: Add multi-browser support with per-browser Local State paths
var chromiumBundleIDs = map[string]bool{
	"com.google.Chrome": true,
}

// Pattern: "Page Title - Browser Name - Profile Name"
// Captures profile name after browser identifier
var profilePattern = regexp.MustCompile(`- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$`)

// ChromeEnricher detects Chrome profile information from window titles
type ChromeEnricher struct {
	// Cached Local State profile info
	// Key: profile directory name (e.g., "Default", "Profile 1")
	// Value: profile metadata
	infoCache     map[string]profileInfo
	infoCacheOnce sync.Once

	// Reverse lookup: display name -> profile directory
	// Needed because AX title shows display name, not directory
	nameToDir map[string]string
}

type profileInfo struct {
	Name     string
	GAIAName string
	UserName string
}

// NewChromeEnricher creates configured Chrome enricher
func NewChromeEnricher() *ChromeEnricher {
	return &ChromeEnricher{}
}

// Supports returns true for Chromium-based browsers
func (e *ChromeEnricher) Supports(bundleID string) bool {
	return chromiumBundleIDs[bundleID]
}

// Enrich detects Chrome profile and returns enrichment
func (e *ChromeEnricher) Enrich(pid int, windowTitle string) *Enrichment {
	// 1. Parse profile name from window title
	matches := profilePattern.FindStringSubmatch(windowTitle)
	if matches == nil {
		// No profile suffix = Default profile or non-profile window
		return &Enrichment{
			Chrome: &ChromeInfo{
				Profile: "Default",
			},
		}
	}
	profileName := matches[1]

	// Empty profile name = Default
	if profileName == "" {
		return &Enrichment{
			Chrome: &ChromeInfo{
				Profile: "Default",
			},
		}
	}

	// 2. Load Local State cache (once)
	e.infoCacheOnce.Do(func() {
		e.loadLocalState()
	})

	// 3. Lookup profile directory and email from cache
	var profileDir, email string
	if e.nameToDir != nil {
		if dir, ok := e.nameToDir[profileName]; ok {
			profileDir = dir
			if info, ok := e.infoCache[dir]; ok {
				email = info.UserName
			}
		}
	}

	// 4. Return enrichment
	return &Enrichment{
		Chrome: &ChromeInfo{
			Profile:    profileName,
			ProfileDir: profileDir,
			Email:      email,
		},
	}
}

// loadLocalState reads Chrome's Local State and builds profile caches
func (e *ChromeEnricher) loadLocalState() {
	// Initialize maps
	e.infoCache = make(map[string]profileInfo)
	e.nameToDir = make(map[string]string)

	// Build Local State path
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	localStatePath := filepath.Join(home,
		"Library", "Application Support", "Google", "Chrome", "Local State")

	// Read and parse JSON
	data, err := os.ReadFile(localStatePath)
	if err != nil {
		// Chrome not installed - silently return
		return
	}

	// Parse structure (reuse from sources/chrome.go)
	var state struct {
		Profile struct {
			InfoCache map[string]struct {
				Name           string `json:"name"`
				GAIAName       string `json:"gaia_name"`
				UserName       string `json:"user_name"`
				IsUsingDefault bool   `json:"is_using_default_name"`
			} `json:"info_cache"`
		} `json:"profile"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		return
	}

	// Build caches
	for dir, info := range state.Profile.InfoCache {
		e.infoCache[dir] = profileInfo{
			Name:     info.Name,
			GAIAName: info.GAIAName,
			UserName: info.UserName,
		}

		// Build reverse lookup (display name -> dir)
		// Use same name resolution logic as sources/chrome.go
		displayName := info.Name
		if displayName == "" || info.IsUsingDefault {
			if info.GAIAName != "" {
				displayName = info.GAIAName
			}
		}
		if displayName != "" {
			e.nameToDir[displayName] = dir
		}
	}
}
