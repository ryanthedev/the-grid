package client

import (
	"context"
	"testing"

	"github.com/ryanthedev/grid-cli/internal/config"
)

func TestSendBorderConfig_NilConfig(t *testing.T) {
	c := &Client{
		conn: nil, // We don't need a real connection for this test
	}

	err := c.SendBorderConfig(context.Background(), nil)
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

	err := c.SendBorderConfig(context.Background(), cfg)
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

