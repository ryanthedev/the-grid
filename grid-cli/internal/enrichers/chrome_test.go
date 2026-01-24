package enrichers

import "testing"

func TestChromeEnricher_Supports(t *testing.T) {
	tests := []struct {
		bundleID string
		expected bool
	}{
		{"com.google.Chrome", true},
		// Other browsers not yet supported (need per-browser Local State paths)
		{"com.google.Chrome.canary", false},
		{"org.chromium.Chromium", false},
		{"com.brave.Browser", false},
		{"com.microsoft.edgemac", false},
		{"com.apple.Safari", false},
		{"com.mitchellh.ghostty", false},
	}

	e := NewChromeEnricher()
	for _, tt := range tests {
		t.Run(tt.bundleID, func(t *testing.T) {
			got := e.Supports(tt.bundleID)
			if got != tt.expected {
				t.Errorf("Supports(%q) = %v, want %v", tt.bundleID, got, tt.expected)
			}
		})
	}
}

func TestChromeEnricher_Enrich(t *testing.T) {
	tests := []struct {
		name          string
		windowTitle   string
		wantProfile   string
		wantPageTitle string
	}{
		{
			name:          "default profile - no suffix",
			windowTitle:   "Google Docs - Google Chrome",
			wantProfile:   "Default",
			wantPageTitle: "Google Docs - Google Chrome",
		},
		{
			name:          "named profile",
			windowTitle:   "Google Docs - Google Chrome - Work",
			wantProfile:   "Work",
			wantPageTitle: "Google Docs",
		},
		{
			name:          "trailing dash no profile",
			windowTitle:   "Page - Google Chrome - ",
			wantProfile:   "Default",
			wantPageTitle: "Page - Google Chrome - ", // No match, keeps original
		},
		{
			name:          "profile with spaces",
			windowTitle:   "Gmail - Google Chrome - Victoria and Ryan",
			wantProfile:   "Victoria and Ryan",
			wantPageTitle: "Gmail",
		},
	}

	e := NewChromeEnricher()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			enrichment := e.Enrich(0, tt.windowTitle)
			if enrichment == nil {
				t.Fatal("Enrich returned nil")
			}
			if enrichment.Chrome == nil {
				t.Fatal("Enrich.Chrome is nil")
			}
			if enrichment.Chrome.Profile != tt.wantProfile {
				t.Errorf("Profile = %q, want %q", enrichment.Chrome.Profile, tt.wantProfile)
			}
			if enrichment.Chrome.PageTitle != tt.wantPageTitle {
				t.Errorf("PageTitle = %q, want %q", enrichment.Chrome.PageTitle, tt.wantPageTitle)
			}
		})
	}
}

func TestEnrichment_Format_ChromeOnly(t *testing.T) {
	enrichment := &Enrichment{
		Chrome: &ChromeInfo{
			Profile:    "Work",
			ProfileDir: "Profile 1",
			Email:      "user@company.com",
			PageTitle:  "Google Docs",
		},
	}
	result := enrichment.Format()
	// Title is the clean page title (without browser/profile suffix)
	if result.Title != "Google Docs" {
		t.Errorf("Title = %q, want %q", result.Title, "Google Docs")
	}
	// Profile goes in subtitle
	if result.Subtitle != "Work" {
		t.Errorf("Subtitle = %q, want %q", result.Subtitle, "Work")
	}
	if result.StableIDSuffix != "chrome:Work" {
		t.Errorf("StableIDSuffix = %q, want %q", result.StableIDSuffix, "chrome:Work")
	}
}
