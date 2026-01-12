package tmux

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestCacheStoreAndLookup(t *testing.T) {
	cache := &Cache{
		Mappings: make(map[string]CacheEntry),
		path:     "/tmp/test-cache.json",
	}

	// Store and lookup
	cache.Store(12345, 67890)
	clientPID, found := cache.Lookup(12345)
	if !found {
		t.Error("Lookup should find stored entry")
	}
	if clientPID != 67890 {
		t.Errorf("Lookup returned %d, want 67890", clientPID)
	}

	// Lookup missing
	_, found = cache.Lookup(99999)
	if found {
		t.Error("Lookup should not find missing entry")
	}
}

func TestCachePrune(t *testing.T) {
	cache := &Cache{
		Mappings: make(map[string]CacheEntry),
		path:     "/tmp/test-cache.json",
	}

	// Store multiple entries
	cache.Store(100, 1)
	cache.Store(200, 2)
	cache.Store(300, 3)

	// Prune - only keep client PID 2
	validPIDs := map[int]bool{2: true}
	cache.Prune(validPIDs)

	// Check results
	if len(cache.Mappings) != 1 {
		t.Errorf("Prune should leave 1 entry, got %d", len(cache.Mappings))
	}

	if _, found := cache.Lookup(200); !found {
		t.Error("Entry with valid client PID should remain")
	}

	if _, found := cache.Lookup(100); found {
		t.Error("Entry with invalid client PID should be pruned")
	}
}

func TestCacheSaveAndLoad(t *testing.T) {
	tmpDir := t.TempDir()
	cachePath := filepath.Join(tmpDir, "thegrid", "tmux-cache.json")

	// Create and save
	cache := &Cache{
		Mappings: make(map[string]CacheEntry),
		path:     cachePath,
	}
	cache.Store(12345, 67890)
	cache.Store(11111, 22222)

	if err := cache.Save(); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	// Verify file exists
	if _, err := os.Stat(cachePath); os.IsNotExist(err) {
		t.Fatal("Cache file was not created")
	}

	// Load into new cache
	loaded := &Cache{
		Mappings: make(map[string]CacheEntry),
		path:     cachePath,
	}

	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}

	if err := loaded.UnmarshalJSON(data); err != nil {
		t.Fatalf("UnmarshalJSON failed: %v", err)
	}

	// Verify entries
	clientPID, found := loaded.Lookup(12345)
	if !found || clientPID != 67890 {
		t.Error("Loaded cache missing entry for 12345")
	}

	clientPID, found = loaded.Lookup(11111)
	if !found || clientPID != 22222 {
		t.Error("Loaded cache missing entry for 11111")
	}
}

func TestLoadCacheMissingFile(t *testing.T) {
	// Temporarily override XDG_STATE_HOME
	tmpDir := t.TempDir()
	oldEnv := os.Getenv("XDG_STATE_HOME")
	os.Setenv("XDG_STATE_HOME", tmpDir)
	defer os.Setenv("XDG_STATE_HOME", oldEnv)

	cache, err := LoadCache()
	if err != nil {
		t.Fatalf("LoadCache should not error on missing file: %v", err)
	}

	if cache == nil {
		t.Fatal("LoadCache should return non-nil cache")
	}

	if len(cache.Mappings) != 0 {
		t.Error("LoadCache should return empty mappings for missing file")
	}
}

// UnmarshalJSON for testing
func (c *Cache) UnmarshalJSON(data []byte) error {
	type cacheAlias Cache
	aux := &cacheAlias{
		Mappings: make(map[string]CacheEntry),
	}
	if err := json.Unmarshal(data, aux); err != nil {
		return err
	}
	c.Mappings = aux.Mappings
	return nil
}
