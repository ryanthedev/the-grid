# Config Cache Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Cache merged config to avoid XDG resolution and merging on every CLI command.

**Architecture:** Add mtime-based caching layer to `LoadConfig()`. Cache stored at `$XDG_CACHE_HOME/thegrid/config.merged.yaml`. Check source file mtimes on each load; rebuild if stale.

**Tech Stack:** Go, YAML, os.Stat for mtime checks

---

## Task 1: Add CacheHome to xdg package

**Files:**
- Modify: `grid-cli/internal/xdg/xdg.go`

**Step 1: Add CacheHome function**

Add after `StateHome()` function (around line 54):

```go
// CacheHome returns $XDG_CACHE_HOME or ~/.cache
func CacheHome() string {
	if env := os.Getenv("XDG_CACHE_HOME"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache")
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/r/repos/theGrid/.worktrees/decouple-border-sync && go build ./grid-cli/...`
Expected: Success, no errors

**Step 3: Commit**

```bash
git add grid-cli/internal/xdg/xdg.go
git commit -m "feat(xdg): add CacheHome for XDG_CACHE_HOME support"
```

---

## Task 2: Add cache types and helpers to loader

**Files:**
- Modify: `grid-cli/internal/config/loader.go`

**Step 1: Verify current imports**

No import changes needed - `time` package is NOT required since `ModTime()` returns `time.Time` and we only call methods on it (`.After()`), which Go handles without explicit import.

**Step 2: Add cache path helper**

Add after `builtinDefaults()` function:

```go
// cachePath returns the path to the merged config cache file
func cachePath() string {
	return filepath.Join(xdg.CacheHome(), "thegrid", "config.merged.yaml")
}
```

**Step 3: Add source files collector**

Add after `cachePath()`:

```go
// getSourceFiles returns all config source files that contribute to merged config
func getSourceFiles() []string {
	files := xdg.FindConfigFiles("thegrid", "config.yaml")
	localPath := filepath.Join(xdg.ConfigHome(), "thegrid", "config.local.yaml")
	if info, err := os.Stat(localPath); err == nil && !info.IsDir() {
		files = append(files, localPath)
	}
	return files
}
```

**Step 4: Verify it compiles**

Run: `cd /Users/r/repos/theGrid/.worktrees/decouple-border-sync && go build ./grid-cli/...`
Expected: Success

**Step 5: Commit**

```bash
git add grid-cli/internal/config/loader.go
git commit -m "feat(config): add cache path and source file helpers"
```

---

## Task 3: Add cache freshness check

**Files:**
- Modify: `grid-cli/internal/config/loader.go`

**Step 1: Add isCacheFresh function**

Add after `getSourceFiles()`:

```go
// isCacheFresh checks if cache exists and is newer than all source files.
// Returns (isFresh, reason) where reason explains why cache is stale.
func isCacheFresh() (bool, string) {
	cache := cachePath()
	cacheInfo, err := os.Stat(cache)
	if err != nil {
		if os.IsNotExist(err) {
			return false, "missing"
		}
		return false, "stat_error"
	}
	cacheMtime := cacheInfo.ModTime()

	sources := getSourceFiles()
	if len(sources) == 0 {
		// No source files exist - cache is stale if it references deleted files
		return false, "no_sources"
	}

	for _, src := range sources {
		srcInfo, err := os.Stat(src)
		if err != nil {
			// Source file was deleted or inaccessible
			return false, "source_deleted"
		}
		if srcInfo.ModTime().After(cacheMtime) {
			return false, "stale"
		}
	}

	return true, ""
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/r/repos/theGrid/.worktrees/decouple-border-sync && go build ./grid-cli/...`
Expected: Success (note: `time` import now used)

**Step 3: Commit**

```bash
git add grid-cli/internal/config/loader.go
git commit -m "feat(config): add cache freshness check with mtime comparison"
```

---

## Task 4: Add cache read/write functions

**Files:**
- Modify: `grid-cli/internal/config/loader.go`

**Step 1: Add writeCache function with atomic write**

Add after `isCacheFresh()`:

```go
// writeCache writes the merged config map to cache file atomically
func writeCache(merged map[string]any, sources []string) error {
	cache := cachePath()
	dir := filepath.Dir(cache)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create cache dir: %w", err)
	}

	data, err := yaml.Marshal(merged)
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Atomic write: write to temp file, then rename
	tmp := cache + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return fmt.Errorf("failed to write cache: %w", err)
	}
	if err := os.Rename(tmp, cache); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("failed to rename cache: %w", err)
	}

	jsonlog.Log("cfg.cache.write", jsonlog.WithData(map[string]any{
		"path":    cache,
		"sources": sources,
	}))

	return nil
}
```

**Step 2: Add loadCache function**

Add after `writeCache()`:

```go
// loadCache reads the cached merged config
func loadCache() (map[string]any, error) {
	data, err := os.ReadFile(cachePath())
	if err != nil {
		return nil, err
	}

	var m map[string]any
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, err
	}

	return m, nil
}
```

**Step 3: Verify it compiles**

Run: `cd /Users/r/repos/theGrid/.worktrees/decouple-border-sync && go build ./grid-cli/...`
Expected: Success

**Step 4: Commit**

```bash
git add grid-cli/internal/config/loader.go
git commit -m "feat(config): add cache read/write functions"
```

---

## Task 5: Integrate caching into loadWithXDG

**Files:**
- Modify: `grid-cli/internal/config/loader.go`

**Step 1: Replace loadWithXDG with cached version**

Replace the entire `loadWithXDG()` function:

```go
// loadWithXDG implements full XDG config resolution with layered merging and caching
func loadWithXDG() (*Config, error) {
	// Check cache freshness (single call to avoid TOCTOU)
	fresh, reason := isCacheFresh()
	if fresh {
		merged, err := loadCache()
		if err == nil {
			jsonlog.Log("cfg.cache.hit")
			cfg, err := mapToConfig(merged)
			if err != nil {
				return nil, fmt.Errorf("failed to unmarshal cached config: %w", err)
			}
			if err := cfg.Validate(); err != nil {
				// Cache is corrupt or schema changed - rebuild
				jsonlog.Log("cfg.cache.miss", jsonlog.WithData(map[string]any{"reason": "validation_failed"}))
			} else {
				return cfg, nil
			}
		} else {
			jsonlog.Log("cfg.cache.miss", jsonlog.WithData(map[string]any{"reason": "read_error"}))
		}
	} else {
		jsonlog.Log("cfg.cache.miss", jsonlog.WithData(map[string]any{"reason": reason}))
	}

	// Cache miss - do full resolution
	files := xdg.FindConfigFiles("thegrid", "config.yaml")
	merged := builtinDefaults()

	jsonlog.Log("cfg.resolve", jsonlog.WithData(map[string]any{
		"xdg_config_home": xdg.ConfigHome(),
		"xdg_config_dirs": xdg.ConfigDirs(),
		"files_found":     files,
	}))

	for _, f := range files {
		layer, err := loadYAMLFile(f)
		if err != nil {
			return nil, fmt.Errorf("failed to parse %s: %w", f, err)
		}
		merged = deepMerge(merged, layer)
		jsonlog.Log("cfg.merge", jsonlog.WithData(map[string]any{"path": f}))
	}

	localPath := filepath.Join(xdg.ConfigHome(), "thegrid", "config.local.yaml")
	if info, err := os.Stat(localPath); err == nil && !info.IsDir() {
		layer, err := loadYAMLFile(localPath)
		if err != nil {
			return nil, fmt.Errorf("failed to parse %s: %w", localPath, err)
		}
		merged = deepMerge(merged, layer)
		jsonlog.Log("cfg.merge", jsonlog.WithData(map[string]any{"path": localPath, "layer": "local"}))
	}

	if len(files) == 0 {
		localInfo, _ := os.Stat(localPath)
		if localInfo == nil {
			return nil, fmt.Errorf("no config found; searched:\n  - %s/thegrid/config.yaml\n  - %s",
				xdg.ConfigHome(), formatSearchedDirs(xdg.ConfigDirs()))
		}
	}

	// Write cache using getSourceFiles() for consistency (ignore errors - best-effort)
	if err := writeCache(merged, getSourceFiles()); err != nil {
		jsonlog.Log("cfg.cache.error", jsonlog.WithMsg("failed to write cache"),
			jsonlog.WithData(map[string]any{"err": err.Error()}))
	}

	cfg, err := mapToConfig(merged)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal merged config: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config after merge: %w", err)
	}

	return cfg, nil
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/r/repos/theGrid/.worktrees/decouple-border-sync && go build ./grid-cli/...`
Expected: Success

**Step 3: Commit**

```bash
git add grid-cli/internal/config/loader.go
git commit -m "feat(config): integrate mtime-based caching into config loading"
```

---

## Task 6: Manual testing

**Step 1: Rebuild and test cache miss (first run)**

```bash
cd /Users/r/repos/theGrid/.worktrees/decouple-border-sync
rm -f ~/.cache/thegrid/config.merged.yaml
make run
thegrid ping
```

Check logs for `cfg.cache.miss` with reason "missing", followed by `cfg.cache.write`.

**Step 2: Test cache hit (second run)**

```bash
thegrid ping
```

Check logs for `cfg.cache.hit` - should NOT see `cfg.resolve` or `cfg.merge`.

**Step 3: Test cache invalidation (touch source)**

```bash
touch ~/.config/thegrid/config.yaml
thegrid ping
```

Check logs for `cfg.cache.miss` with reason "stale", followed by rebuild.

**Step 4: Verify cache file exists**

```bash
cat ~/.cache/thegrid/config.merged.yaml
```

Expected: Valid YAML with merged settings.

---

## Summary

After implementation:
- First CLI command: cache miss → full XDG resolution → write cache
- Subsequent commands: mtime check → cache hit (fast path)
- Config edit: mtime check detects stale → rebuild cache

Expected logs:
- `cfg.cache.hit` - using cached config
- `cfg.cache.miss` - rebuilding (reason: missing/stale/source_deleted/validation_failed/read_error)
- `cfg.cache.write` - wrote new cache
- `cfg.cache.error` - failed to write cache (non-fatal)
