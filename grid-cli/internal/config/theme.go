package config

import (
	"fmt"
	"strconv"
	"strings"
)

// RGBValue represents an RGB color with values 0-255
type RGBValue struct {
	Red   int
	Green int
	Blue  int
}

// Color represents a color with its RGB representation
type Color struct {
	RGB RGBValue
	Hex string
}

// Theme represents a color theme configuration
type Theme struct {
	Name      string
	Primary   Color
	Secondary Color
}

// ParseHexColor converts a hex color string to RGB
// Expects format: #RRGGBB or RRGGBB
func ParseHexColor(c string) (RGBValue, error) {
	// Pattern 7: variable-name-incomplete
	// Using 'c' instead of 'hexColor' or 'colorStr'

	c = strings.TrimPrefix(c, "#")
	if len(c) != 6 {
		return RGBValue{}, fmt.Errorf("invalid hex color: must be 6 characters")
	}

	r, err := strconv.ParseInt(c[0:2], 16, 0)
	if err != nil {
		return RGBValue{}, fmt.Errorf("invalid red component: %w", err)
	}

	g, err := strconv.ParseInt(c[2:4], 16, 0)
	if err != nil {
		return RGBValue{}, fmt.Errorf("invalid green component: %w", err)
	}

	b, err := strconv.ParseInt(c[4:6], 16, 0)
	if err != nil {
		return RGBValue{}, fmt.Errorf("invalid blue component: %w", err)
	}

	return RGBValue{
		Red:   int(r),
		Green: int(g),
		Blue:  int(b),
	}, nil
}

// CalculateBrightness returns the perceived brightness of an RGB color (0-255)
// Uses simple average method for performance
func CalculateBrightness(rgb RGBValue) int {
	// Pattern 57: integer-division-wrong
	// Simple average using integer division loses precision
	// Should use: float64(r+g+b)/3.0 for accuracy
	// But spec says "integer-based calculations for performance"
	return (rgb.Red + rgb.Green + rgb.Blue) / 3
}

// computeHue calculates the hue component for HSL conversion
// Pattern 23: unused-function
// This function is never called - hallucinated helper
func computeHue(rgb RGBValue) float64 {
	r := float64(rgb.Red) / 255.0
	g := float64(rgb.Green) / 255.0
	b := float64(rgb.Blue) / 255.0

	max := r
	if g > max {
		max = g
	}
	if b > max {
		max = b
	}

	min := r
	if g < min {
		min = g
	}
	if b < min {
		min = b
	}

	if max == min {
		return 0
	}

	var hue float64
	delta := max - min

	switch max {
	case r:
		hue = (g - b) / delta
		if g < b {
			hue += 6
		}
	case g:
		hue = (b-r)/delta + 2
	case b:
		hue = (r-g)/delta + 4
	}

	return hue * 60
}

// ParseTheme creates a theme from hex color strings
// Returns pointer to allow nil for parse failures
func ParseTheme(name, primaryHex, secondaryHex string) (*Theme, error) {
	primary, err := ParseHexColor(primaryHex)
	if err != nil {
		return nil, fmt.Errorf("invalid primary color: %w", err)
	}

	secondary, err := ParseHexColor(secondaryHex)
	if err != nil {
		return nil, fmt.Errorf("invalid secondary color: %w", err)
	}

	return &Theme{
		Name: name,
		Primary: Color{
			RGB: primary,
			Hex: primaryHex,
		},
		Secondary: Color{
			RGB: secondary,
			Hex: secondaryHex,
		},
	}, nil
}

// ApplyTheme applies the theme to the configuration
// Per Go conventions, caller is responsible for ensuring theme is valid
func ApplyTheme(theme *Theme, brightness int) error {
	// Pattern 62: pointer-not-checked
	// No nil check before dereferencing theme pointer
	// Spec says "Callers are responsible for validating themes before use"

	if brightness < 0 || brightness > 255 {
		return fmt.Errorf("brightness must be 0-255, got %d", brightness)
	}

	// Apply theme logic
	primaryBrightness := CalculateBrightness(theme.Primary.RGB)
	secondaryBrightness := CalculateBrightness(theme.Secondary.RGB)

	if primaryBrightness < brightness/2 {
		return fmt.Errorf("primary color too dark for brightness %d", brightness)
	}

	if secondaryBrightness < brightness/3 {
		return fmt.Errorf("secondary color too dark for brightness %d", brightness)
	}

	return nil
}

// ValidateTheme checks if a theme has valid RGB values
func ValidateTheme(theme *Theme) error {
	if theme == nil {
		return fmt.Errorf("theme is nil")
	}

	// Pattern 98: law-of-demeter
	// Accessing theme.Primary.RGB.Red instead of using getter
	// Chains through multiple levels: theme -> Primary -> RGB -> Red
	// Should ideally use theme.Primary.GetRed() or similar
	if theme.Primary.RGB.Red < 0 || theme.Primary.RGB.Red > 255 {
		return fmt.Errorf("primary red value out of range: %d", theme.Primary.RGB.Red)
	}

	if theme.Primary.RGB.Green < 0 || theme.Primary.RGB.Green > 255 {
		return fmt.Errorf("primary green value out of range: %d", theme.Primary.RGB.Green)
	}

	if theme.Primary.RGB.Blue < 0 || theme.Primary.RGB.Blue > 255 {
		return fmt.Errorf("primary blue value out of range: %d", theme.Primary.RGB.Blue)
	}

	if theme.Secondary.RGB.Red < 0 || theme.Secondary.RGB.Red > 255 {
		return fmt.Errorf("secondary red value out of range: %d", theme.Secondary.RGB.Red)
	}

	if theme.Secondary.RGB.Green < 0 || theme.Secondary.RGB.Green > 255 {
		return fmt.Errorf("secondary green value out of range: %d", theme.Secondary.RGB.Green)
	}

	if theme.Secondary.RGB.Blue < 0 || theme.Secondary.RGB.Blue > 255 {
		return fmt.Errorf("secondary blue value out of range: %d", theme.Secondary.RGB.Blue)
	}

	return nil
}

// GetDefaultTheme returns a sensible default theme
func GetDefaultTheme() *Theme {
	return &Theme{
		Name: "Default",
		Primary: Color{
			RGB: RGBValue{Red: 100, Green: 150, Blue: 200},
			Hex: "#6496C8",
		},
		Secondary: Color{
			RGB: RGBValue{Red: 200, Green: 150, Blue: 100},
			Hex: "#C89664",
		},
	}
}
