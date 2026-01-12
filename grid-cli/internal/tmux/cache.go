package tmux

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/xdg"
)

const cacheFilename = "tmux-cache.json"

// Cache stores window PID to tmux client PID mappings
type Cache struct {
	Mappings map[string]CacheEntry `json:"mappings"`
	path     string
}

// CacheEntry represents a cached mapping
type CacheEntry struct {
	ClientPID int   `json:"clientPID"`
	CachedAt  int64 `json:"cachedAt"`
}

// LoadCache loads the cache from disk or creates an empty one.
// Returns empty cache (not error) if file doesn't exist or can't be read.
func LoadCache() (*Cache, error) {
	path := filepath.Join(xdg.StateHome(), "thegrid", cacheFilename)

	cache := &Cache{
		Mappings: make(map[string]CacheEntry),
		path:     path,
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			jsonlog.Log("tmux.cache_read_err", jsonlog.WithMsg("using empty cache"),
				jsonlog.WithData(map[string]any{"path": path, "err": err.Error()}))
		}
		return cache, nil
	}

	if err := json.Unmarshal(data, cache); err != nil {
		jsonlog.Log("tmux.cache_parse_err", jsonlog.WithMsg("using empty cache"),
			jsonlog.WithData(map[string]any{"path": path, "err": err.Error()}))
		cache.Mappings = make(map[string]CacheEntry)
	}

	cache.path = path
	return cache, nil
}

// Save writes the cache to disk
func (c *Cache) Save() error {
	// Ensure parent directory exists
	dir := filepath.Dir(c.path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(c.path, data, 0644)
}

// Lookup returns the cached client PID for a window PID
func (c *Cache) Lookup(windowPID int) (clientPID int, found bool) {
	key := strconv.Itoa(windowPID)
	entry, ok := c.Mappings[key]
	if !ok {
		return 0, false
	}
	return entry.ClientPID, true
}

// Store saves a window PID to client PID mapping
func (c *Cache) Store(windowPID, clientPID int) {
	key := strconv.Itoa(windowPID)
	c.Mappings[key] = CacheEntry{
		ClientPID: clientPID,
		CachedAt:  time.Now().Unix(),
	}
}

// Prune removes entries where clientPID is no longer valid
func (c *Cache) Prune(validClientPIDs map[int]bool) {
	for key, entry := range c.Mappings {
		if !validClientPIDs[entry.ClientPID] {
			delete(c.Mappings, key)
		}
	}
}
