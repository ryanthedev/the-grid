package enrichers

import "testing"

func TestRegistry_Enrich_NoMatch(t *testing.T) {
	reg := NewRegistry()
	result := reg.Enrich("com.apple.Safari", 12345, "Safari")
	if result != nil {
		t.Errorf("Non-terminal app should return nil, got %+v", result)
	}
}

func TestRegistry_NewRegistry(t *testing.T) {
	reg := NewRegistry()
	if reg == nil {
		t.Fatal("NewRegistry returned nil")
	}
	if len(reg.enrichers) != 3 {
		t.Errorf("Expected 3 enrichers, got %d", len(reg.enrichers))
	}
}

func TestRegistry_CacheOperations(t *testing.T) {
	reg := NewRegistry()

	// RefreshCaches should not panic
	reg.RefreshCaches()

	// Cleanup should not panic
	reg.Cleanup()

	// ClientPIDs should return valid slice (possibly empty)
	pids := reg.ClientPIDs()
	if pids == nil {
		// nil is acceptable when no tmux clients
	}
}
