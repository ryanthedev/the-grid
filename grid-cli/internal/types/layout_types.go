package types

// StackMode defines how multiple windows in a cell are arranged
type StackMode string

const (
	StackVertical   StackMode = "vertical"
	StackHorizontal StackMode = "horizontal"
	StackTabs       StackMode = "tabs"
)

// TrackSize represents a grid track dimension (column or row)
// Supports: "1fr", "2fr", "300px", "auto", "minmax(200px, 1fr)"
type TrackSize struct {
	Type  TrackType // Type of track sizing
	Value float64   // Primary value (for fr/px)
	Min   float64   // Minimum value (for minmax)
	Max   float64   // Maximum value (for minmax)
}

// TrackType categorizes track sizing methods
type TrackType string

const (
	TrackFr     TrackType = "fr"     // Fractional unit
	TrackPx     TrackType = "px"     // Fixed pixels
	TrackAuto   TrackType = "auto"   // Content-based
	TrackMinMax TrackType = "minmax" // Constrained flexible
)

// Cell represents a grid cell definition from configuration
type Cell struct {
	ID          string    // Unique cell identifier
	ColumnStart int       // 1-indexed column start
	ColumnEnd   int       // 1-indexed column end (exclusive)
	RowStart    int       // 1-indexed row start
	RowEnd      int       // 1-indexed row end (exclusive)
	StackMode   StackMode // How windows stack in this cell (optional override)
}

// Layout defines a complete grid layout configuration
type Layout struct {
	ID          string               // Unique layout identifier
	Name        string               // Human-readable name
	Description string               // Optional description
	Columns     []TrackSize          // Column track definitions
	Rows        []TrackSize          // Row track definitions
	Cells       []Cell               // Cell definitions
	CellModes   map[string]StackMode // Per-cell stack mode overrides
}

// Rect represents pixel bounds on screen
type Rect struct {
	X      float64 // Left edge (pixels from screen left)
	Y      float64 // Top edge (pixels from screen top)
	Width  float64 // Width in pixels
	Height float64 // Height in pixels
}

// Point represents a 2D coordinate
type Point struct {
	X float64
	Y float64
}

// Center returns the center point of a Rect
func (r Rect) Center() Point {
	return Point{
		X: r.X + r.Width/2,
		Y: r.Y + r.Height/2,
	}
}

// Contains checks if a point is inside the rect
func (r Rect) Contains(p Point) bool {
	return p.X >= r.X && p.X <= r.X+r.Width &&
		p.Y >= r.Y && p.Y <= r.Y+r.Height
}

// Overlap returns the area of intersection between two Rects
func (r Rect) Overlap(other Rect) float64 {
	left := max(r.X, other.X)
	right := min(r.X+r.Width, other.X+other.Width)
	top := max(r.Y, other.Y)
	bottom := min(r.Y+r.Height, other.Y+other.Height)

	if left >= right || top >= bottom {
		return 0
	}
	return (right - left) * (bottom - top)
}

// CellBounds contains calculated pixel positions for a cell
type CellBounds struct {
	CellID string // Reference to cell definition
	Bounds Rect   // Calculated pixel bounds
}

// WindowPlacement specifies where a window should be positioned
type WindowPlacement struct {
	WindowID uint32 // Window identifier from server
	Bounds   Rect   // Target position and size
}

// CalculatedLayout contains all computed bounds for a layout
type CalculatedLayout struct {
	LayoutID    string          // Reference to layout definition
	ScreenRect  Rect            // Screen bounds used for calculation
	Gap         float64         // Gap between cells in pixels
	ColumnSizes []float64       // Calculated column widths
	RowSizes    []float64       // Calculated row heights
	CellBounds  map[string]Rect // cellID -> calculated bounds
}

// Direction represents navigation direction
type Direction int

const (
	DirLeft Direction = iota
	DirRight
	DirUp
	DirDown
)

// String returns the string representation of a Direction
func (d Direction) String() string {
	switch d {
	case DirLeft:
		return "left"
	case DirRight:
		return "right"
	case DirUp:
		return "up"
	case DirDown:
		return "down"
	default:
		return "unknown"
	}
}

// ParseDirection converts a string to Direction
func ParseDirection(s string) (Direction, bool) {
	switch s {
	case "left":
		return DirLeft, true
	case "right":
		return DirRight, true
	case "up":
		return DirUp, true
	case "down":
		return DirDown, true
	default:
		return 0, false
	}
}

// AssignmentStrategy defines how windows are distributed to cells
type AssignmentStrategy int

const (
	AssignAutoFlow AssignmentStrategy = iota // Even distribution
	AssignPinned                             // Use app rules
	AssignPreserve                           // Maintain previous assignments
	AssignPosition                           // Assign based on current window position
)
