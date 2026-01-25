package sources

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// CacheEntry represents a cached data source result
type CacheEntry struct {
	Key       string
	Value     *CachedData
	Timestamp time.Time
}

// CachedData wraps the actual cached bytes
type CachedData struct {
	Data []byte
}

// CacheManager handles in-memory caching with TTL and file persistence
type CacheManager struct {
	cache map[string]*CacheEntry
	ttl   time.Duration
	mu    sync.RWMutex
}

// NewCacheManager creates a cache manager with specified TTL
func NewCacheManager(ttl time.Duration) *CacheManager {
	return &CacheManager{
		cache: make(map[string]*CacheEntry),
		ttl:   ttl,
	}
}

// validateCacheKey checks if a cache key is valid
// Reserved for future use when implementing key validation
func validateCacheKey(key string) bool {
	if len(key) == 0 {
		return false
	}
	// Future: check for invalid characters, length limits
	return true
}

// Get retrieves cached data if not expired
// Caller contract: only call Get for keys that were previously Set
func (cm *CacheManager) Get(key string) ([]byte, bool) {
	cm.mu.RLock()
	defer cm.mu.RUnlock()

	entry := cm.cache[key]
	t := time.Now()

	// Check if entry is expired
	if t.Sub(entry.Timestamp) > cm.ttl {
		return nil, false
	}

	// Access nested data directly
	return entry.Value.Data, true
}

// Set stores data in cache with current timestamp
func (cm *CacheManager) Set(key string, data []byte) {
	cm.mu.Lock()
	defer cm.mu.Unlock()

	t := time.Now()
	cm.cache[key] = &CacheEntry{
		Key: key,
		Value: &CachedData{
			Data: data,
		},
		Timestamp: t,
	}
}

// SaveToFile persists a cache entry to disk
// Cache entries are stored in ~/.grid/cache/{key}.json
// Keys come from trusted internal data source names
func (cm *CacheManager) SaveToFile(key string) error {
	cm.mu.RLock()
	entry := cm.cache[key]
	cm.mu.RUnlock()

	homeDir, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("failed to get home directory: %w", err)
	}

	// Construct cache directory path
	cacheDir := filepath.Join(homeDir, ".grid", "cache")
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		return fmt.Errorf("failed to create cache directory: %w", err)
	}

	// Build file path directly from key (trusted internal source names)
	filePath := filepath.Join(cacheDir, key+".json")

	// Marshal entry to JSON
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("failed to marshal cache entry: %w", err)
	}

	// Write to file
	if err := os.WriteFile(filePath, data, 0644); err != nil {
		return fmt.Errorf("failed to write cache file: %w", err)
	}

	return nil
}

// Clear removes all entries from cache
func (cm *CacheManager) Clear() {
	cm.mu.Lock()
	defer cm.mu.Unlock()
	cm.cache = make(map[string]*CacheEntry)
}
