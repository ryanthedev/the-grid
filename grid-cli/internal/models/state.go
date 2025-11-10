package models

import (
	"encoding/json"
	"fmt"
	"time"
)

// State represents the complete window manager state
type State struct {
	Windows      map[string]*Window      `json:"windows"`
	Spaces       map[string]*Space       `json:"spaces"`
	Displays     []*Display              `json:"displays"`
	Applications map[string]*Application `json:"applications"`
	Metadata     *StateMetadata          `json:"metadata"`
}

// Window represents a window in the system
type Window struct {
	ID           int                    `json:"id"`
	Title        string                 `json:"title"`
	AppName      string                 `json:"appName"`
	PID          int                    `json:"pid"`
	Frame        [][]interface{}        `json:"frame"` // [[x, y], [width, height]] - can contain float64 or bool for overflow
	Spaces       []interface{}          `json:"spaces"` // Can be int or bool for large uint64
	IsMinimized  bool                   `json:"isMinimized"`
	IsOrderedIn  bool                   `json:"isOrderedIn"`
	Alpha        float64                `json:"alpha"`   // Window transparency (0.0-1.0)
	Level        interface{}            `json:"level"`
	SubLevel     interface{}            `json:"subLevel"`
	HasTransform bool                   `json:"hasTransform"`
	Metadata     map[string]interface{} `json:"metadata"`
}

// toFloat64 converts interface{} to float64, handling bool for overflow
func toFloat64(v interface{}) float64 {
	switch val := v.(type) {
	case float64:
		return val
	case int:
		return float64(val)
	case bool:
		// Bool represents overflow - return a large number
		return 9999999.0
	default:
		return 0
	}
}

// GetX returns the window's X position
func (w *Window) GetX() float64 {
	if len(w.Frame) > 0 && len(w.Frame[0]) > 0 {
		return toFloat64(w.Frame[0][0])
	}
	return 0
}

// GetY returns the window's Y position
func (w *Window) GetY() float64 {
	if len(w.Frame) > 0 && len(w.Frame[0]) > 1 {
		return toFloat64(w.Frame[0][1])
	}
	return 0
}

// GetWidth returns the window's width
func (w *Window) GetWidth() float64 {
	if len(w.Frame) > 1 && len(w.Frame[1]) > 0 {
		return toFloat64(w.Frame[1][0])
	}
	return 0
}

// GetHeight returns the window's height
func (w *Window) GetHeight() float64 {
	if len(w.Frame) > 1 && len(w.Frame[1]) > 1 {
		return toFloat64(w.Frame[1][1])
	}
	return 0
}

// GetPrimarySpace returns the first space ID the window is on
func (w *Window) GetPrimarySpace() string {
	if len(w.Spaces) > 0 {
		switch v := w.Spaces[0].(type) {
		case int:
			return fmt.Sprintf("%d", v)
		case float64:
			return fmt.Sprintf("%.0f", v)
		case bool:
			return "large"
		default:
			return fmt.Sprintf("%v", v)
		}
	}
	return "-"
}

// FormatFrame returns a formatted string representation of the window frame
func (w *Window) FormatFrame() string {
	return fmt.Sprintf("%.0fx%.0f @ (%.0f, %.0f)", w.GetWidth(), w.GetHeight(), w.GetX(), w.GetY())
}

// Space represents a macOS space
type Space struct {
	ID          interface{}            `json:"id"` // Can be int or bool for large uint64
	UUID        string                 `json:"uuid"`
	Type        string                 `json:"type"`
	DisplayUUID string                 `json:"displayUUID"`
	IsActive    bool                   `json:"isActive"`
	Windows     []interface{}          `json:"windows"` // Can be int or bool for large uint64
	Metadata    map[string]interface{} `json:"metadata"`
}

// GetIDString returns the space ID as a string
func (s *Space) GetIDString() string {
	switch v := s.ID.(type) {
	case int:
		return fmt.Sprintf("%d", v)
	case float64:
		return fmt.Sprintf("%.0f", v)
	case bool:
		// Bool represents large uint64 that couldn't be unmarshaled
		return "large"
	default:
		return fmt.Sprintf("%v", v)
	}
}

// GetWindowCount returns the number of windows in this space
func (s *Space) GetWindowCount() int {
	return len(s.Windows)
}

// Rect represents a rectangle (CGRect from Swift)
type Rect struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// Display represents a display/monitor
type Display struct {
	UUID           string        `json:"uuid"`
	Spaces         []interface{} `json:"spaces"` // Can be int or bool for large uint64
	CurrentSpaceID interface{}   `json:"currentSpaceID"`

	// Core display properties
	DisplayID          interface{} `json:"displayID,omitempty"`          // Can be int or bool for overflow
	Name               *string     `json:"name,omitempty"`
	Frame              interface{} `json:"frame,omitempty"`              // Ignore - using pixelWidth/pixelHeight instead
	VisibleFrame       interface{} `json:"visibleFrame,omitempty"`       // Ignore - using pixelWidth/pixelHeight instead
	BackingScaleFactor *float64    `json:"backingScaleFactor,omitempty"`
	IsMain             *bool       `json:"isMain,omitempty"`
	PixelWidth         *int        `json:"pixelWidth,omitempty"`
	PixelHeight        *int        `json:"pixelHeight,omitempty"`

	// Enhanced properties
	ColorSpace       *string  `json:"colorSpace,omitempty"`
	RefreshRate      *float64 `json:"refreshRate,omitempty"`
	PhysicalWidthMM  *float64 `json:"physicalWidthMM,omitempty"`
	PhysicalHeightMM *float64 `json:"physicalHeightMM,omitempty"`
	IsBuiltin        *bool    `json:"isBuiltin,omitempty"`
}

// GetSpaceIDs returns the space IDs as strings
func (d *Display) GetSpaceIDs() []string {
	ids := make([]string, 0, len(d.Spaces))
	for _, s := range d.Spaces {
		switch v := s.(type) {
		case int:
			ids = append(ids, fmt.Sprintf("%d", v))
		case float64:
			ids = append(ids, fmt.Sprintf("%.0f", v))
		case bool:
			ids = append(ids, "large")
		default:
			ids = append(ids, fmt.Sprintf("%v", v))
		}
	}
	return ids
}

// GetCurrentSpaceIDString returns the current space ID as a string
func (d *Display) GetCurrentSpaceIDString() string {
	switch v := d.CurrentSpaceID.(type) {
	case int:
		return fmt.Sprintf("%d", v)
	case float64:
		return fmt.Sprintf("%.0f", v)
	case bool:
		return "large"
	default:
		return fmt.Sprintf("%v", v)
	}
}

// GetDisplayName returns the display name or a fallback
func (d *Display) GetDisplayName() string {
	if d.Name != nil && *d.Name != "" {
		return *d.Name
	}
	// Fallback to UUID prefix
	if len(d.UUID) > 8 {
		return d.UUID[:8]
	}
	return d.UUID
}

// GetResolutionString returns formatted resolution (e.g., "3840x2160")
func (d *Display) GetResolutionString() string {
	if d.PixelWidth != nil && d.PixelHeight != nil {
		return fmt.Sprintf("%dx%d", *d.PixelWidth, *d.PixelHeight)
	}
	return "-"
}

// GetScaleString returns formatted scale factor (e.g., "2x")
func (d *Display) GetScaleString() string {
	if d.BackingScaleFactor != nil {
		return fmt.Sprintf("%.0fx", *d.BackingScaleFactor)
	}
	return "-"
}

// GetRefreshRateString returns formatted refresh rate (e.g., "120 Hz")
func (d *Display) GetRefreshRateString() string {
	if d.RefreshRate != nil && *d.RefreshRate > 0 {
		return fmt.Sprintf("%.0f Hz", *d.RefreshRate)
	}
	return "-"
}

// IsMainDisplay returns true if this is the main display
func (d *Display) IsMainDisplay() bool {
	return d.IsMain != nil && *d.IsMain
}

// GetDisplayIDString returns formatted display ID (e.g., "1")
func (d *Display) GetDisplayIDString() string {
	if d.DisplayID != nil {
		return fmt.Sprintf("%v", d.DisplayID)
	}
	return "-"
}

// IsBuiltinDisplay returns true if this is a built-in display (laptop screen)
func (d *Display) IsBuiltinDisplay() bool {
	return d.IsBuiltin != nil && *d.IsBuiltin
}

// Application represents an application
type Application struct {
	PID                     int                    `json:"pid"`
	BundleIdentifier        string                 `json:"bundleIdentifier"`
	LocalizedName           string                 `json:"localizedName"`
	BundleURL               string                 `json:"bundleURL"`
	ExecutableURL           string                 `json:"executableURL"`
	ExecutableArchitecture  string                 `json:"executableArchitecture"`
	LaunchDate              time.Time              `json:"launchDate"`
	IsActive                bool                   `json:"isActive"`
	IsHidden                bool                   `json:"isHidden"`
	IsFinishedLaunching     bool                   `json:"isFinishedLaunching"`
	ActivationPolicy        string                 `json:"activationPolicy"`
	Windows                 []interface{}          `json:"windows"` // Can be int or bool for large uint64
	Metadata                map[string]interface{} `json:"metadata"`
}

// GetWindowCount returns the number of windows for this application
func (a *Application) GetWindowCount() int {
	return len(a.Windows)
}

// StateMetadata contains metadata about the state
type StateMetadata struct {
	Timestamp    time.Time `json:"timestamp"`
	ConnectionID int32     `json:"connectionID"`
}

// ParseState parses the dump result into a State struct
func ParseState(result map[string]interface{}) (*State, error) {
	data, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal state: %w", err)
	}

	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("failed to unmarshal state: %w", err)
	}

	return &state, nil
}

// GetWindows returns all windows as a slice
func (s *State) GetWindows() []*Window {
	windows := make([]*Window, 0, len(s.Windows))
	for _, w := range s.Windows {
		windows = append(windows, w)
	}
	return windows
}

// GetApplications returns all applications as a slice
func (s *State) GetApplications() []*Application {
	apps := make([]*Application, 0, len(s.Applications))
	for _, a := range s.Applications {
		apps = append(apps, a)
	}
	return apps
}

// FindWindowByID finds a window by its ID
func (s *State) FindWindowByID(id int) *Window {
	return s.Windows[fmt.Sprintf("%d", id)]
}

// FindApplicationByPID finds an application by its PID
func (s *State) FindApplicationByPID(pid int) *Application {
	return s.Applications[fmt.Sprintf("%d", pid)]
}
