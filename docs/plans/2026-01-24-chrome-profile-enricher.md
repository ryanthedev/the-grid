# Plan: Chrome Profile Enricher

**Created:** 2026-01-24
**Status:** complete

## Context

The window picker shows Chrome windows but doesn't distinguish between profiles. When you have multiple Chrome profiles (Work, Personal, etc.), all Chrome windows look the same in the picker.

Chrome includes the profile name in the full window title (via Accessibility API), but the server currently uses `kCGWindowName` which only returns the page title.

## Constraints

- Chrome runs all profiles in a single process (PID won't distinguish profiles)
- `kCGWindowName` returns page title only: `"Google Gemini"`
- `kAXTitleAttribute` returns full title: `"Google Gemini - Google Chrome - ProfileName"`
- AppleScript has no native profile detection (Chromium bug #174117)
- Profile metadata is in `~/Library/Application Support/Google/Chrome/Local State`

## Chosen Approach

**Server-side AX title + CLI enricher with Local State mapping**

Two-phase fix:
1. Server provides full AX title (not just CG page title)
2. CLI enricher parses profile from title and enriches with Local State metadata

This was chosen over:
- CLI-side osascript workaround (adds latency, fragile window matching)
- PID-based detection (doesn't work - single process for all profiles)

## Implementation Checklist

### Phase 1: Server - Expose AX Title

- [x] Modify `extractAXProperties()` in StateManager.swift to fetch `kAXTitleAttribute`
- [x] Add `title` field to `AXWindowProperties` struct
- [x] In window scan, prefer AX title over CG title when available
- [x] Test: Chrome windows show full title including profile suffix

**Files:**
- `grid-server/Sources/GridServer/StateManager.swift`

**Details:**
In `extractAXProperties()`, add after existing attribute fetches:
```swift
// Get title (AX title includes browser suffix like "- Chrome - ProfileName")
var titleValue: CFTypeRef?
if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue) == .success {
    props.title = titleValue as? String
}
```

Update the window scan to use this:
```swift
// Prefer AX title over CG title (AX includes profile for Chrome)
if let axTitle = axProps.title, !axTitle.isEmpty {
    windowState.title = axTitle
} else if let name = windowInfo[kCGWindowName as String] as? String, !name.isEmpty {
    windowState.title = name
}
```

### Phase 2: CLI - Enricher Categories

- [x] Refactor `Enrichment` struct to have categories: terminal vs browser
- [x] Add `Category` field or use separate type for chrome enrichment
- [x] Update `Format()` to handle browser category separately from terminal

**Files:**
- `grid-cli/internal/enrichers/types.go`

**Details:**
Add ChromeInfo to Enrichment:
```go
type Enrichment struct {
    SSH    *SSHInfo    `json:"ssh,omitempty"`
    Tmux   *TmuxInfo   `json:"tmux,omitempty"`
    Chrome *ChromeInfo `json:"chrome,omitempty"`
}

type ChromeInfo struct {
    Profile     string `json:"profile"`
    ProfileDir  string `json:"profile_dir,omitempty"`
    Email       string `json:"email,omitempty"`
}
```

Update Format() to handle Chrome-only enrichment (it won't combine with SSH/Tmux):
```go
if e.HasChrome() && !e.HasSSH() && !e.HasTmux() {
    result.Title = e.Chrome.Profile
    result.StableIDSuffix = "chrome:" + e.Chrome.Profile
}
```

### Phase 3: CLI - Chrome Enricher

- [x] Create `chrome.go` with ChromeEnricher struct
- [x] Implement `Supports()` for Chromium-based browsers (Chrome only for now)
- [x] Implement `Enrich()` to parse profile from title
- [x] Load and cache Local State for profile metadata
- [x] Register in Registry

**Files:**
- `grid-cli/internal/enrichers/chrome.go` (new)
- `grid-cli/internal/enrichers/chrome_test.go` (new)
- `grid-cli/internal/enrichers/registry.go`

**Details:**

Supported bundle IDs:
```go
var chromiumBundleIDs = map[string]bool{
    "com.google.Chrome":        true,
    "com.google.Chrome.canary": true,
    "org.chromium.Chromium":    true,
    "com.brave.Browser":        true,
    "com.microsoft.edgemac":    true,
}
```

Title parsing pattern:
```go
// Pattern: "Page Title - Browser Name - Profile Name"
// Examples:
//   "Google Gemini - Google Chrome - Victoria and Ryan"
//   "GitHub - Google Chrome - Ryan (ryanthedev.com)"
//   "New Tab - Brave"  (no profile = Default)
var profilePattern = regexp.MustCompile(`- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$`)
```

Local State loading:
```go
func loadLocalState() (map[string]ProfileInfo, error) {
    path := filepath.Join(os.Getenv("HOME"),
        "Library/Application Support/Google/Chrome/Local State")
    data, err := os.ReadFile(path)
    // Parse JSON, extract profile.info_cache
}
```

### Phase 4: Test and Integrate

- [x] Unit tests for profile parsing (various title formats)
- [x] Unit tests for Local State parsing (via integration)
- [x] Integration test: picker shows profile names for Chrome windows
- [x] Update registry enricher count test

**Files:**
- `grid-cli/internal/enrichers/chrome_test.go`
- `grid-cli/internal/enrichers/registry_test.go`

## Test Plan

- [x] Unit: Profile parsed from "Page - Chrome - ProfileName" format
- [x] Unit: Default returned when no profile suffix present
- [x] Unit: Local State JSON parsed correctly
- [ ] Unit: Brave, Edge, Chromium bundle IDs supported (deferred - needs per-browser paths)
- [x] Integration: `thegrid dump` shows full AX title for Chrome windows
- [x] Integration: Picker shows profile name in enriched output

## Notes

**Edge Cases:**
- Incognito windows: Title may show "(Incognito)" but that's not a profile
- Guest windows: Title shows "Guest"
- Extensions/DevTools: May not have profile suffix
- Multiple Chrome installs: Different Local State paths (Canary, etc.)

**Profile name sources:**
- `name` field in Local State - user-set name or email domain
- `gaia_name` - Google account name
- `user_name` - email address

Use `name` as primary since that's what appears in the title bar.

## Execution Log

### Phase 1: Server - Expose AX Title
- Added `title: String?` to `AXWindowProperties` struct
- Modified `extractAXProperties()` to fetch `kAXTitleAttribute`
- Updated 4 window state paths to prefer AX title over CG title
- Commit: 44016fc

### Phase 2: CLI - Enricher Categories
- Added `ChromeInfo` struct with Profile, ProfileDir, Email fields
- Added `Chrome` field to `Enrichment` struct
- Added `HasChrome()` method and updated `Merge()`
- Added `chromeOnly` branch to `Format()`
- Commit: 6d06888

### Phase 3: CLI - Chrome Enricher
- Created `chrome.go` with `ChromeEnricher`
- Implemented profile parsing from AX title via regex
- Implemented Local State JSON loading with sync.Once caching
- Restricted to Chrome-only (other browsers need per-browser Local State paths)
- Registered in Registry
- Commit: 43a48d8

### Phase 4: Test and Integrate
- All unit tests pass (15/15 enricher tests)
- Integration verified: `thegrid dump` shows full AX titles
- Example: "Google Gemini - Google Chrome - Victoria and Ryan"
- Server rebuilt and deployed
