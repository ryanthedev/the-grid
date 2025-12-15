package client

import (
	"testing"

	"github.com/yourusername/grid-cli/internal/config"
)

func TestSendBorderConfig_NilConfig(t *testing.T) {
	c := &Client{
		conn: nil, // We don't need a real connection for this test
	}

	err := c.SendBorderConfig(nil)
	if err != nil {
		t.Errorf("Expected no error for nil config, got: %v", err)
	}
}

func TestSendBorderConfig_DisabledConfig(t *testing.T) {
	c := &Client{
		conn: nil,
	}

	enabled := false
	cfg := &config.BorderConfig{
		Enabled: &enabled,
	}

	err := c.SendBorderConfig(cfg)
	if err != nil {
		t.Errorf("Expected no error for disabled config, got: %v", err)
	}
}

func TestCellAssignment_Structure(t *testing.T) {
	assignment := CellAssignment{
		WindowID: 123,
		CellID:   "main",
	}

	if assignment.WindowID != 123 {
		t.Errorf("Expected WindowID 123, got %d", assignment.WindowID)
	}
	if assignment.CellID != "main" {
		t.Errorf("Expected CellID 'main', got %s", assignment.CellID)
	}
}

func TestCellOverride_Structure(t *testing.T) {
	override := CellOverride{
		ActiveCellColor: "0xFF0000",
		InactiveColor:   "0x00FF00",
		Style:           "round",
	}

	if override.ActiveCellColor != "0xFF0000" {
		t.Errorf("Expected ActiveCellColor 0xFF0000, got %s", override.ActiveCellColor)
	}
	if override.InactiveColor != "0x00FF00" {
		t.Errorf("Expected InactiveColor 0x00FF00, got %s", override.InactiveColor)
	}
	if override.Style != "round" {
		t.Errorf("Expected Style 'round', got %s", override.Style)
	}
}
