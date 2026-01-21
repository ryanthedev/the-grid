package sources

import (
	"context"
	"testing"
)

func TestExecuteAction_UnknownType(t *testing.T) {
	err := ExecuteAction(context.Background(), Action{Type: "invalid"})
	if err == nil {
		t.Error("expected error for unknown action type")
	}
}

func TestExecuteAction_FocusWindowReturnsError(t *testing.T) {
	// focus-window should return error since caller handles it
	err := ExecuteAction(context.Background(), Action{Type: "focus-window", WindowID: 123})
	if err == nil {
		t.Error("expected error for focus-window action")
	}
}

func TestExecuteAction_MissingFields(t *testing.T) {
	tests := []struct {
		name   string
		action Action
	}{
		{"open-app missing path", Action{Type: "open-app"}},
		{"chrome missing profile", Action{Type: "open-chrome-profile"}},
		{"exec missing command", Action{Type: "exec"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ExecuteAction(context.Background(), tt.action)
			if err == nil {
				t.Error("expected error for missing required field")
			}
		})
	}
}
