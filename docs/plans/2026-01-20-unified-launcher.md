# Plan: Unified Application Launcher

**Created:** 2026-01-20
**Status:** complete

## Context

Build a Raycast/Spotlight-style unified launcher that searches windows, apps, Chrome profiles, and custom actions in a single picker interface. Merges functionality from the standalone `dalauncher` project into theGrid.

## Constraints

- Merge dalauncher code into theGrid (not separate repos)
- CLI-driven discovery (Approach A) - Go handles all source discovery
- Native overlay picker (grid-picker) for UI
- Global frecency sorting across all sources
- Hybrid icons: SF Symbols + actual app icons

## Requirements

| Requirement | Decision |
|-------------|----------|
| Sources | Windows, apps, Chrome profiles, custom actions |
| Invocation | `thegrid pick` with `--only`/`--exclude` filters |
| Item actions | Self-describing (each item carries its action) |
| Config | Merged into `~/.config/thegrid/config.yaml` |
| Toggle mode | Dropped - invoke fresh each time |
| Icons | Hybrid: SF Symbols for categories + app icons |
| Sorting | Global frecency (frequency + recency) |

## Future Sources (designed for extensibility)

- tmux sessions
- zoxide directories
- Any CLI tool that outputs text

---

## Phase 1: Icon Support in Picker

Add icon rendering to grid-picker.

### Changes

- `PickerItem` gains `iconPath: String?` (file path to .icns/.png) and `iconSymbol: String?` (SF Symbol name)
- `PickerRenderer` draws 16x16 or 20x20 icon left of title
- SF Symbols via `NSImage(systemSymbolName:)`
- App icons loaded from path via `NSImage(contentsOfFile:)`

### Files

- Modify: `grid-server/Sources/GridPicker/PickerItem.swift`
- Modify: `grid-server/Sources/GridPicker/PickerRenderer.swift`

---

## Phase 2: Source Discovery in CLI

Port dalauncher's discovery logic into grid-cli, plus add window source.

### New Files

- `grid-cli/internal/sources/apps.go` - Scan /Applications, /System/Applications, ~/Applications
- `grid-cli/internal/sources/chrome.go` - Parse Chrome Local State for profiles
- `grid-cli/internal/sources/actions.go` - Load custom actions from config
- `grid-cli/internal/sources/windows.go` - Refactor existing window picker logic
- `grid-cli/internal/sources/sources.go` - Common PickerItem type with action field, DiscoverAll() orchestrator

### PickerItem Structure

```go
type PickerItem struct {
    ID         string            `json:"id"`
    Title      string            `json:"title"`
    Subtitle   string            `json:"subtitle,omitempty"`
    Searchable []string          `json:"searchable"`
    IconPath   string            `json:"iconPath,omitempty"`   // /Applications/Slack.app/Contents/Resources/icon.icns
    IconSymbol string            `json:"iconSymbol,omitempty"` // SF Symbol name
    Action     Action            `json:"action"`
    Metadata   map[string]string `json:"metadata,omitempty"`
}

type Action struct {
    Type string `json:"type"` // "focus-window", "exec", "open-app", "open-chrome-profile"
    // Type-specific fields
    WindowID   int    `json:"windowId,omitempty"`
    Command    string `json:"command,omitempty"`
    AppPath    string `json:"appPath,omitempty"`
    ProfileDir string `json:"profileDir,omitempty"`
}
```

### Icon Extraction for Apps

```go
// Get icon path from app bundle
func getAppIconPath(appPath string) string {
    plistPath := filepath.Join(appPath, "Contents", "Info.plist")
    // Parse plist, get CFBundleIconFile
    // Return full path: appPath/Contents/Resources/{iconFile}.icns
}
```

---

## Phase 3: Action Execution

After picker returns selected item, CLI executes the action based on type.

### New File

- `grid-cli/internal/sources/executor.go`

### Executor Logic

```go
func ExecuteAction(action Action) error {
    switch action.Type {
    case "focus-window":
        // Existing window focus logic via RPC
        return client.FocusWindow(action.WindowID)

    case "open-app":
        // open -a "/Applications/Slack.app"
        return exec.Command("open", "-a", action.AppPath).Run()

    case "open-chrome-profile":
        // open -na "Google Chrome" --args --profile-directory="Profile 1"
        return exec.Command("open", "-na", "Google Chrome", "--args",
            "--profile-directory="+action.ProfileDir).Run()

    case "exec":
        // Custom action - run via shell
        return exec.Command("sh", "-c", action.Command).Run()
    }
    return fmt.Errorf("unknown action type: %s", action.Type)
}
```

### Future Action Types (reserved)

- `tmux-attach` - `tmux attach -t {session}`
- `open-dir` - `open {path}` or spawn terminal at path
- `zoxide-jump` - `zoxide add {path}` + open

---

## Phase 4: Config Integration

Merge source configuration into existing theGrid config.

### Modify

- `grid-cli/internal/config/config.go`

### New Config Section

```yaml
# ~/.config/thegrid/config.yaml
picker:
  sources:
    windows: true      # enabled by default
    apps: true         # scan /Applications etc
    chrome:
      enabled: true
      stateFile: ~/Library/Application Support/Google/Chrome/Local State
    actions: true      # load custom actions below

  actions:
    - name: "New Terminal"
      command: "open -na Ghostty"
      category: "Actions"
      icon: "terminal"  # SF Symbol

    - name: "Lock Screen"
      command: "pmset displaysleepnow"
      category: "System"
      icon: "lock"
```

### Config Struct Additions

```go
type PickerConfig struct {
    Sources SourcesConfig `yaml:"sources"`
    Actions []ActionConfig `yaml:"actions"`
}

type SourcesConfig struct {
    Windows bool         `yaml:"windows"`
    Apps    bool         `yaml:"apps"`
    Chrome  ChromeConfig `yaml:"chrome"`
    Actions bool         `yaml:"actions"`
}

type ChromeConfig struct {
    Enabled   bool   `yaml:"enabled"`
    StateFile string `yaml:"stateFile"`
}

type ActionConfig struct {
    Name     string `yaml:"name"`
    Command  string `yaml:"command"`
    Category string `yaml:"category"`
    Icon     string `yaml:"icon"` // SF Symbol name
}
```

---

## Phase 5: Global Frecency

Extend existing picker history to track all sources with frecency scoring.

### Modify

- `grid-cli/internal/state/picker_history.go`

### New Structure

```go
type PickerHistory struct {
    Items map[string]*HistoryEntry `json:"items"` // keyed by item ID
}

type HistoryEntry struct {
    ID          string    `json:"id"`          // e.g., "app:slack", "window:tmux:dev:nvim", "action:lock-screen"
    SelectCount int       `json:"selectCount"` // total selections
    LastUsed    time.Time `json:"lastUsed"`    // for recency
}

// Frecency score: combines frequency and recency
// Higher = more relevant
func (e *HistoryEntry) FrecencyScore() float64 {
    hoursSinceUse := time.Since(e.LastUsed).Hours()
    recencyWeight := 1.0 / (1.0 + hoursSinceUse/24.0) // decay over days
    return float64(e.SelectCount) * recencyWeight
}
```

### Item ID Conventions

- Windows: `window:{stableID}` (existing stable ID logic)
- Apps: `app:{bundleID}` or `app:{appName}`
- Chrome: `chrome:{profileDir}`
- Actions: `action:{name-slug}`

### Sorting

```go
func SortByFrecency(items []PickerItem, history *PickerHistory) {
    sort.SliceStable(items, func(i, j int) bool {
        scoreI := history.GetScore(items[i].ID)
        scoreJ := history.GetScore(items[j].ID)
        if scoreI != scoreJ {
            return scoreI > scoreJ // higher score first
        }
        return items[i].Title < items[j].Title // alphabetic fallback
    })
}
```

### Storage

`~/.local/state/thegrid/picker-history.json`

---

## Phase 6: Unified Pick Command

Refactor `thegrid pick` to be the unified entry point.

### Modify

- `grid-cli/cmd/grid/main.go`

### New Command Structure

```
thegrid pick                    # all sources
thegrid pick --only windows     # just windows (current behavior)
thegrid pick --only apps,actions
thegrid pick --exclude chrome
thegrid pick window             # alias for --only windows (backwards compat)
```

### Implementation

```go
var pickCmd = &cobra.Command{
    Use:   "pick",
    Short: "Unified launcher - search windows, apps, actions",
    RunE:  runPick,
}

func init() {
    pickCmd.Flags().StringSlice("only", nil, "Only show these sources (windows,apps,chrome,actions)")
    pickCmd.Flags().StringSlice("exclude", nil, "Exclude these sources")

    // Keep 'pick window' as subcommand for backwards compatibility
    pickCmd.AddCommand(pickWindowCmd)
}

func runPick(cmd *cobra.Command, args []string) error {
    only, _ := cmd.Flags().GetStringSlice("only")
    exclude, _ := cmd.Flags().GetStringSlice("exclude")

    // Determine which sources to enable
    enabledSources := resolveEnabledSources(cfg.Picker.Sources, only, exclude)

    // Discover items from each enabled source (parallel)
    items := sources.DiscoverAll(enabledSources, cfg)

    // Load history and sort by frecency
    history, _ := state.LoadPickerHistory()
    sources.SortByFrecency(items, history)

    // Launch picker
    result, err := launchPicker(items, cfg.Settings.PickerPath)
    if err != nil {
        return err
    }

    if result.Cancelled {
        return nil
    }

    // Record selection in history
    history.Record(result.Selected.ID)
    history.Save()

    // Execute action
    return sources.ExecuteAction(result.Selected.Action)
}
```

---

## Phase 7: Picker Protocol Update

Update the JSON protocol between CLI and grid-picker to support icons and actions.

### Current Protocol

- CLI sends: `[{id, title, subtitle, searchable, metadata}]`
- Picker returns: `{cancelled: bool, selected: PickerItem}`

### New Protocol

- CLI sends: `[{id, title, subtitle, searchable, iconPath, iconSymbol, action, metadata}]`
- Picker returns: `{cancelled: bool, selected: PickerItem}` (unchanged - action passes through)

### Modify

- `grid-server/Sources/GridPicker/PickerItem.swift`

```swift
struct PickerItem: Codable {
    let id: String
    let title: String
    let subtitle: String?
    let searchable: [String]
    let iconPath: String?    // NEW: path to .icns or .png
    let iconSymbol: String?  // NEW: SF Symbol name
    let action: Action       // NEW: passed through to result
    let metadata: [String: String]?
}

struct Action: Codable {
    let type: String
    let windowId: Int?
    let command: String?
    let appPath: String?
    let profileDir: String?
}
```

### Icon Loading in Renderer

```swift
func loadIcon(for item: PickerItem) -> NSImage? {
    // Prefer SF Symbol if specified
    if let symbol = item.iconSymbol {
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
    // Fall back to file path
    if let path = item.iconPath {
        return NSImage(contentsOfFile: path)
    }
    return nil
}
```

---

## Phase 8: Validation & Testing

Verify end-to-end functionality.

### Unit Tests

- `sources/apps_test.go` - Mock filesystem, verify app discovery
- `sources/chrome_test.go` - Mock Local State JSON, verify profile parsing
- `sources/executor_test.go` - Verify action type routing (mock exec)
- `state/picker_history_test.go` - Frecency scoring, record/load

### Manual Validation Checklist

- [ ] `thegrid pick` shows windows, apps, Chrome profiles, actions
- [ ] Icons render correctly (app icons + SF Symbols)
- [ ] Fuzzy search works across all sources
- [ ] Selecting app launches it
- [ ] Selecting window focuses it
- [ ] Selecting Chrome profile opens it
- [ ] Selecting action executes command
- [ ] Frecency sorting works (repeat selections float up)
- [ ] `--only windows` filters correctly
- [ ] `--exclude chrome` filters correctly
- [ ] `thegrid pick window` backwards compat works
- [ ] Config changes (disable source) take effect

---

## Phase Summary

| Phase | Description | Files |
|-------|-------------|-------|
| 1 | Icon support in picker | PickerItem.swift, PickerRenderer.swift |
| 2 | Source discovery in CLI | internal/sources/*.go (5 files) |
| 3 | Action execution | internal/sources/executor.go |
| 4 | Config integration | internal/config/config.go |
| 5 | Global frecency | internal/state/picker_history.go |
| 6 | Unified pick command | cmd/grid/main.go |
| 7 | Picker protocol update | PickerItem.swift |
| 8 | Validation | *_test.go files, manual testing |
