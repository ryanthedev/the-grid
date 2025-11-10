package output

import (
	"math"

	"github.com/yourusername/grid-cli/internal/models"
)

// ScalingContext handles coordinate transformation from pixel space to terminal character space
type ScalingContext struct {
	// Display bounds in pixels
	MinX, MinY float64
	MaxX, MaxY float64

	// Display dimensions in pixels
	PixelWidth  float64
	PixelHeight float64

	// Terminal dimensions in characters
	TermWidth  int
	TermHeight int

	// Scale factors
	ScaleX float64
	ScaleY float64

	// Aspect ratio correction (terminal characters are typically 2:1 height:width)
	AspectRatio float64
}

// NewScalingContextFromDisplay creates a scaling context using actual display dimensions
func NewScalingContextFromDisplay(display *models.Display, termWidth, termHeight int) *ScalingContext {
	// Use actual display dimensions if available
	if display.PixelWidth != nil && display.PixelHeight != nil {
		pixelWidth := float64(*display.PixelWidth)
		pixelHeight := float64(*display.PixelHeight)

		// Reserve space for borders (2 characters on each side)
		availWidth := termWidth - 4
		availHeight := termHeight - 4

		if availWidth < 10 {
			availWidth = 10
		}
		if availHeight < 5 {
			availHeight = 5
		}

		scaleX := float64(availWidth) / pixelWidth
		scaleY := float64(availHeight) / pixelHeight

		return &ScalingContext{
			MinX:        0,
			MinY:        0,
			MaxX:        pixelWidth,
			MaxY:        pixelHeight,
			PixelWidth:  pixelWidth,
			PixelHeight: pixelHeight,
			TermWidth:   termWidth,
			TermHeight:  termHeight,
			ScaleX:      scaleX,
			ScaleY:      scaleY,
			AspectRatio: 2.0,
		}
	}

	// Fallback to default if no display dimensions available
	return &ScalingContext{
		MinX:        0,
		MinY:        0,
		MaxX:        1920,
		MaxY:        1080,
		PixelWidth:  1920,
		PixelHeight: 1080,
		TermWidth:   termWidth,
		TermHeight:  termHeight,
		ScaleX:      float64(termWidth-4) / 1920.0,
		ScaleY:      float64(termHeight-4) / 1080.0,
		AspectRatio: 2.0,
	}
}

// NewScalingContext creates a new scaling context from windows and terminal size
func NewScalingContext(windows []*models.Window, termWidth, termHeight int) *ScalingContext {
	if len(windows) == 0 {
		// Default to 1920x1080 if no windows
		return &ScalingContext{
			MinX:        0,
			MinY:        0,
			MaxX:        1920,
			MaxY:        1080,
			PixelWidth:  1920,
			PixelHeight: 1080,
			TermWidth:   termWidth,
			TermHeight:  termHeight,
			ScaleX:      float64(termWidth) / 1920.0,
			ScaleY:      float64(termHeight) / 1080.0,
			AspectRatio: 2.0,
		}
	}

	// Calculate bounding box from window positions
	minX := math.MaxFloat64
	minY := math.MaxFloat64
	maxX := -math.MaxFloat64
	maxY := -math.MaxFloat64

	for _, win := range windows {
		if win.IsMinimized {
			continue
		}

		x := win.GetX()
		y := win.GetY()
		w := win.GetWidth()
		h := win.GetHeight()

		if x < minX {
			minX = x
		}
		if y < minY {
			minY = y
		}
		if x+w > maxX {
			maxX = x + w
		}
		if y+h > maxY {
			maxY = y + h
		}
	}

	// Add 5% padding
	paddingX := (maxX - minX) * 0.05
	paddingY := (maxY - minY) * 0.05
	minX -= paddingX
	minY -= paddingY
	maxX += paddingX
	maxY += paddingY

	// Ensure minimum size
	if maxX-minX < 800 {
		center := (minX + maxX) / 2
		minX = center - 400
		maxX = center + 400
	}
	if maxY-minY < 600 {
		center := (minY + maxY) / 2
		minY = center - 300
		maxY = center + 300
	}

	pixelWidth := maxX - minX
	pixelHeight := maxY - minY

	// Reserve space for borders (2 characters on each side for display border)
	availWidth := termWidth - 4
	availHeight := termHeight - 4

	if availWidth < 10 {
		availWidth = 10
	}
	if availHeight < 5 {
		availHeight = 5
	}

	scaleX := float64(availWidth) / pixelWidth
	scaleY := float64(availHeight) / pixelHeight

	return &ScalingContext{
		MinX:        minX,
		MinY:        minY,
		MaxX:        maxX,
		MaxY:        maxY,
		PixelWidth:  pixelWidth,
		PixelHeight: pixelHeight,
		TermWidth:   termWidth,
		TermHeight:  termHeight,
		ScaleX:      scaleX,
		ScaleY:      scaleY,
		AspectRatio: 2.0, // Terminal characters are roughly 2:1
	}
}

// PixelToTerminal converts pixel coordinates to terminal coordinates
func (sc *ScalingContext) PixelToTerminal(x, y float64) (int, int) {
	// Offset from minimum bounds
	relX := x - sc.MinX
	relY := y - sc.MinY

	// Scale to terminal space
	termX := int(relX * sc.ScaleX)
	termY := int(relY * sc.ScaleY / sc.AspectRatio)

	// Add offset for border (2 characters)
	termX += 2
	termY += 2

	return termX, termY
}

// ScaleSize converts pixel dimensions to terminal character dimensions
func (sc *ScalingContext) ScaleSize(w, h float64) (int, int) {
	termW := int(w * sc.ScaleX)
	termH := int(h * sc.ScaleY / sc.AspectRatio)

	// Minimum size of 3x2 for visibility
	if termW < 3 {
		termW = 3
	}
	if termH < 2 {
		termH = 2
	}

	return termW, termH
}

// ClampToCanvas ensures coordinates are within canvas bounds
func (sc *ScalingContext) ClampToCanvas(x, y, w, h int) (int, int, int, int) {
	// Clamp position
	if x < 0 {
		w += x
		x = 0
	}
	if y < 0 {
		h += y
		y = 0
	}

	// Clamp size
	if x+w >= sc.TermWidth {
		w = sc.TermWidth - x - 1
	}
	if y+h >= sc.TermHeight {
		h = sc.TermHeight - y - 1
	}

	// Ensure minimum size
	if w < 3 {
		w = 3
	}
	if h < 2 {
		h = 2
	}

	return x, y, w, h
}
