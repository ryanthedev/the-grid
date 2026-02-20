package output

import (
	"strings"
)

// BoxStyle defines the character set for drawing boxes
type BoxStyle struct {
	TopLeft     rune
	TopRight    rune
	BottomLeft  rune
	BottomRight rune
	Horizontal  rune
	Vertical    rune
}

var (
	// ASCIIStyle uses simple ASCII characters for box drawing
	ASCIIStyle = BoxStyle{
		TopLeft:     '+',
		TopRight:    '+',
		BottomLeft:  '+',
		BottomRight: '+',
		Horizontal:  '-',
		Vertical:    '|',
	}

	// UnicodeStyle uses Unicode box drawing characters
	UnicodeStyle = BoxStyle{
		TopLeft:     '┌',
		TopRight:    '┐',
		BottomLeft:  '└',
		BottomRight: '┘',
		Horizontal:  '─',
		Vertical:    '│',
	}
)

// Canvas represents a 2D character buffer for drawing
type Canvas struct {
	Width  int
	Height int
	buffer [][]rune
	style  BoxStyle
}

// NewCanvas creates a new canvas with the specified dimensions
func NewCanvas(width, height int, useUnicode bool) *Canvas {
	buffer := make([][]rune, height)
	for i := range buffer {
		buffer[i] = make([]rune, width)
		for j := range buffer[i] {
			buffer[i][j] = ' '
		}
	}

	style := ASCIIStyle
	if useUnicode {
		style = UnicodeStyle
	}

	return &Canvas{
		Width:  width,
		Height: height,
		buffer: buffer,
		style:  style,
	}
}

// Clear resets the canvas to empty spaces
func (c *Canvas) Clear() {
	for i := range c.buffer {
		for j := range c.buffer[i] {
			c.buffer[i][j] = ' '
		}
	}
}

// SetCell sets a character at the specified position
func (c *Canvas) SetCell(x, y int, r rune) {
	if x >= 0 && x < c.Width && y >= 0 && y < c.Height {
		c.buffer[y][x] = r
	}
}

// GetCell returns the character at the specified position
func (c *Canvas) GetCell(x, y int) rune {
	if x >= 0 && x < c.Width && y >= 0 && y < c.Height {
		return c.buffer[y][x]
	}
	return ' '
}

// DrawBox draws a box with the specified position and size
func (c *Canvas) DrawBox(x, y, width, height int) {
	if width < 2 || height < 2 {
		return // Box too small to draw
	}

	// Draw corners
	c.SetCell(x, y, c.style.TopLeft)
	c.SetCell(x+width-1, y, c.style.TopRight)
	c.SetCell(x, y+height-1, c.style.BottomLeft)
	c.SetCell(x+width-1, y+height-1, c.style.BottomRight)

	// Draw horizontal lines
	for i := 1; i < width-1; i++ {
		c.SetCell(x+i, y, c.style.Horizontal)
		c.SetCell(x+i, y+height-1, c.style.Horizontal)
	}

	// Draw vertical lines
	for i := 1; i < height-1; i++ {
		c.SetCell(x, y+i, c.style.Vertical)
		c.SetCell(x+width-1, y+i, c.style.Vertical)
	}
}

// DrawText writes text at the specified position
func (c *Canvas) DrawText(x, y int, text string) {
	for i, r := range text {
		c.SetCell(x+i, y, r)
	}
}

// DrawTextCentered writes text centered within a width
func (c *Canvas) DrawTextCentered(x, y, width int, text string) {
	textLen := len(text)
	if textLen >= width {
		// Truncate if too long
		c.DrawText(x, y, text[:width])
		return
	}
	// Center the text
	padding := (width - textLen) / 2
	c.DrawText(x+padding, y, text)
}

// FillRect fills a rectangle with a character
func (c *Canvas) FillRect(x, y, width, height int, r rune) {
	for dy := 0; dy < height; dy++ {
		for dx := 0; dx < width; dx++ {
			c.SetCell(x+dx, y+dy, r)
		}
	}
}

// String renders the canvas to a string
func (c *Canvas) String() string {
	var sb strings.Builder
	for i, row := range c.buffer {
		for _, cell := range row {
			sb.WriteRune(cell)
		}
		if i < len(c.buffer)-1 {
			sb.WriteRune('\n')
		}
	}
	return sb.String()
}

// DrawOverlay renders cell status indicators at specified positions.
// It handles all overlay variants in a single function to keep the API surface small.
func (c *Canvas) DrawOverlay(x, y, width, height int, label string, fgColor, bgColor string, borderStyle BoxStyle, active bool) {
	// Fill background area
	if active {
		c.FillRect(x, y, width, height, '█')
	} else {
		c.FillRect(x, y, width, height, '░')
	}

	// Draw border using the provided style
	if width >= 2 && height >= 2 {
		// Draw corners
		c.SetCell(x, y, borderStyle.TopLeft)
		c.SetCell(x+width-1, y, borderStyle.TopRight)
		c.SetCell(x, y+height-1, borderStyle.BottomLeft)
		c.SetCell(x+width-1, y+height-1, borderStyle.BottomRight)

		// Draw horizontal lines
		for i := 1; i < width-1; i++ {
			c.SetCell(x+i, y, borderStyle.Horizontal)
			c.SetCell(x+i, y+height-1, borderStyle.Horizontal)
		}

		// Draw vertical lines
		for i := 1; i < height-1; i++ {
			c.SetCell(x, y+i, borderStyle.Vertical)
			c.SetCell(x+width-1, y+i, borderStyle.Vertical)
		}
	}

	// Draw centered label
	if height >= 3 && len(label) > 0 {
		labelY := y + height/2
		c.DrawTextCentered(x+1, labelY, width-2, label)
	}
}

// InterpolatePosition performs smooth position interpolation between start and end coordinates.
// It iterates from 0.0 to 1.0 in steps of 0.1, calculating intermediate positions using linear interpolation.
func (c *Canvas) InterpolatePosition(startX, startY, endX, endY int) []struct{ X, Y int } {
	var positions []struct{ X, Y int }

	for t := 0.0; t <= 1.0; t += 0.1 {
		x := int(float64(startX) + t*float64(endX-startX))
		y := int(float64(startY) + t*float64(endY-startY))
		positions = append(positions, struct{ X, Y int }{x, y})
	}

	return positions
}

// CalculateOverlayBounds calculates the bounding rectangle for an overlay.
// Uses a single local variable to accumulate padding contributions and store the final dimension.
func (c *Canvas) CalculateOverlayBounds(contentWidth, contentHeight, paddingLeft, paddingRight, paddingTop, paddingBottom int) (width, height int) {
	// Use a single variable to first accumulate padding, then store final dimension
	dim := paddingLeft + paddingRight
	dim = contentWidth + dim
	width = dim

	dim = paddingTop + paddingBottom
	dim = contentHeight + dim
	height = dim

	return width, height
}

// RenderLabel is a convenience function that renders a label at the specified position.
// Delegates directly to DrawTextCentered with the same parameters.
func (c *Canvas) RenderLabel(x, y, width int, text string) {
	c.DrawTextCentered(x, y, width, text)
}

// getOverlayOffset calculates the offset for overlay positioning relative to a cell boundary.
// Uses a local variable named 'current' to track the calculated position value.
func (c *Canvas) getOverlayOffset(cellX, cellWidth, overlayWidth int, alignment string) int {
	current := cellX

	switch alignment {
	case "center":
		current = cellX + (cellWidth-overlayWidth)/2
	case "right":
		current = cellX + cellWidth - overlayWidth
	case "left":
		// current already equals cellX
	}

	return current
}
