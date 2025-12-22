# XDG Config Resolution Design

## Overview

Implement full XDG Base Directory Specification compliance for config file loading in both the Go CLI and Swift server components.

## Current State

- CLI config: hardcoded to `~/.config/thegrid/config.yaml`
- BFD config: hardcoded to `~/.config/thegrid/bfd.yaml`
- Both support `.local.yaml` overlay for machine-specific overrides
- No support for `$XDG_CONFIG_HOME` or `$XDG_CONFIG_DIRS` environment variables
- No system-wide config support

## Goals

1. Respect XDG environment variables (`$XDG_CONFIG_HOME`, `$XDG_CONFIG_DIRS`, `$XDG_STATE_HOME`)
2. Support system-wide defaults that users can override
3. Enable Homebrew/package managers to ship default configs
4. Maintain backwards compatibility with existing user configs
5. Provide debugging tools to understand config resolution

## Design

### Merge Order (Layered)

Configs are deep-merged in this order (lowest to highest priority):

```
1. Built-in defaults (hardcoded in code)
2. System configs ($XDG_CONFIG_DIRS/thegrid/, right-to-left)
3. User config ($XDG_CONFIG_HOME/thegrid/)
4. Local overlay ($XDG_CONFIG_HOME/thegrid/*.local.yaml)
```

### Explicit Path Behavior

When `--config /path/to/file` is provided, XDG resolution is **completely bypassed**:
- Only the specified file is loaded
- No system configs are merged
- No `.local.yaml` overlay is applied
- This gives users full control when they need it

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `$XDG_CONFIG_HOME` | `~/.config` | User config directory |
| `$XDG_CONFIG_DIRS` | `/etc/xdg` | Colon-separated system config paths |
| `$XDG_STATE_HOME` | `~/.local/state` | Runtime state (logs, etc.) |

Per XDG spec:
- Empty string means "use default", not "no path"
- Paths in `$XDG_CONFIG_DIRS` must be absolute (relative paths are ignored)
- Empty segments from `::` are ignored

### macOS-Specific Paths

On macOS, append Homebrew paths to the default config dirs search:

```
/etc/xdg:/opt/homebrew/etc:/usr/local/etc
```

This allows `brew install thegrid` to ship defaults at `/opt/homebrew/etc/thegrid/config.yaml`.

### Merge Semantics

- **Objects**: deep merge (nested keys merge recursively)
- **Arrays**: replace entirely (no append)
- **Scalars**: override (higher priority wins)
- **`null` value**: explicitly removes key from lower layers
- **Missing files**: silently skipped

### Files Affected

| File | Component | Notes |
|------|-----------|-------|
| `config.yaml` | CLI (Go) | Main layout/settings config |
| `bfd.yaml` | Server (Swift) | Hotkey configuration |

### State Files

Log files respect `$XDG_STATE_HOME`:
- `$XDG_STATE_HOME/thegrid/thegrid-cli.json` (default: `~/.local/state/thegrid/thegrid-cli.json`)
- `$XDG_STATE_HOME/thegrid/thegrid-server.json` (default: `~/.local/state/thegrid/thegrid-server.json`)

## Implementation

### Go CLI (`internal/xdg/xdg.go`)

```go
package xdg

import (
    "os"
    "path/filepath"
    "runtime"
    "strings"

    "github.com/yourusername/grid-cli/internal/jsonlog"
)

// ConfigHome returns $XDG_CONFIG_HOME or ~/.config
func ConfigHome() string {
    if env := os.Getenv("XDG_CONFIG_HOME"); env != "" {
        return env
    }
    home, _ := os.UserHomeDir()
    return filepath.Join(home, ".config")
}

// ConfigDirs returns validated $XDG_CONFIG_DIRS as slice, or platform defaults.
// Filters out empty segments and relative paths per XDG spec.
func ConfigDirs() []string {
    var dirs []string

    if env := os.Getenv("XDG_CONFIG_DIRS"); env != "" {
        for _, d := range strings.Split(env, ":") {
            // Skip empty segments and relative paths
            if d == "" || !filepath.IsAbs(d) {
                continue
            }
            dirs = append(dirs, d)
        }
        if len(dirs) > 0 {
            return dedup(dirs)
        }
    }

    // Platform defaults
    dirs = []string{"/etc/xdg"}
    if runtime.GOOS == "darwin" {
        dirs = append(dirs, "/opt/homebrew/etc", "/usr/local/etc")
    }
    return dirs
}

// StateHome returns $XDG_STATE_HOME or ~/.local/state
func StateHome() string {
    if env := os.Getenv("XDG_STATE_HOME"); env != "" {
        return env
    }
    home, _ := os.UserHomeDir()
    return filepath.Join(home, ".local", "state")
}

// FindConfigFiles returns existing config files in merge order (system -> user).
// Logs warnings for permission errors, silently skips missing files.
func FindConfigFiles(appName, filename string) []string {
    var paths []string
    seen := make(map[string]bool)

    // System dirs (reverse so first entry in XDG_CONFIG_DIRS has highest priority)
    dirs := ConfigDirs()
    for i := len(dirs) - 1; i >= 0; i-- {
        path := filepath.Join(dirs[i], appName, filename)
        if seen[path] {
            continue
        }
        seen[path] = true

        info, err := os.Stat(path)
        if err != nil {
            if !os.IsNotExist(err) {
                // Permission error or other issue - log and skip
                jsonlog.Log("cfg.skip", jsonlog.WithMsg("cannot access file"),
                    jsonlog.WithData(map[string]any{"path": path, "err": err.Error()}))
            }
            continue
        }
        if info.IsDir() {
            continue
        }
        paths = append(paths, path)
    }

    // User config
    userPath := filepath.Join(ConfigHome(), appName, filename)
    if !seen[userPath] {
        info, err := os.Stat(userPath)
        if err != nil {
            if !os.IsNotExist(err) {
                jsonlog.Log("cfg.skip", jsonlog.WithMsg("cannot access file"),
                    jsonlog.WithData(map[string]any{"path": userPath, "err": err.Error()}))
            }
        } else if !info.IsDir() {
            paths = append(paths, userPath)
        }
    }

    return paths
}

// dedup removes duplicate paths while preserving order
func dedup(paths []string) []string {
    seen := make(map[string]bool)
    var result []string
    for _, p := range paths {
        if !seen[p] {
            seen[p] = true
            result = append(result, p)
        }
    }
    return result
}
```

### Go CLI (`internal/config/loader.go`) - New File

Manual YAML loading with deep merge (replaces Viper-based approach):

```go
package config

import (
    "fmt"
    "os"
    "path/filepath"
    "reflect"

    "gopkg.in/yaml.v3"

    "github.com/yourusername/grid-cli/internal/jsonlog"
    "github.com/yourusername/grid-cli/internal/xdg"
)

// LoadConfig loads configuration using XDG resolution.
// If path is provided, bypasses XDG and loads only that file (no layering).
func LoadConfig(path string) (*Config, error) {
    if path != "" {
        // Explicit path: load single file, no layering
        return loadSingleFile(path)
    }

    return loadWithXDG()
}

// loadWithXDG implements full XDG config resolution with layered merging
func loadWithXDG() (*Config, error) {
    files := xdg.FindConfigFiles("thegrid", "config.yaml")

    // Start with built-in defaults
    merged := builtinDefaults()

    // Log resolution start
    jsonlog.Log("cfg.resolve", jsonlog.WithData(map[string]any{
        "xdg_config_home": xdg.ConfigHome(),
        "xdg_config_dirs": xdg.ConfigDirs(),
        "files_found":     files,
    }))

    // Merge each file in order (system -> user)
    for _, f := range files {
        layer, err := loadYAMLFile(f)
        if err != nil {
            return nil, fmt.Errorf("failed to parse %s: %w", f, err)
        }
        merged = deepMerge(merged, layer)
        jsonlog.Log("cfg.merge", jsonlog.WithData(map[string]any{"path": f}))
    }

    // Apply .local.yaml overlay (highest priority)
    localPath := filepath.Join(xdg.ConfigHome(), "thegrid", "config.local.yaml")
    if info, err := os.Stat(localPath); err == nil && !info.IsDir() {
        layer, err := loadYAMLFile(localPath)
        if err != nil {
            return nil, fmt.Errorf("failed to parse %s: %w", localPath, err)
        }
        merged = deepMerge(merged, layer)
        jsonlog.Log("cfg.merge", jsonlog.WithData(map[string]any{"path": localPath, "layer": "local"}))
    }

    // No config files found at all
    if len(files) == 0 {
        localInfo, _ := os.Stat(localPath)
        if localInfo == nil {
            return nil, fmt.Errorf("no config found; searched:\n  - %s/thegrid/config.yaml\n  - %s",
                xdg.ConfigHome(), formatSearchedDirs(xdg.ConfigDirs()))
        }
    }

    // Convert merged map to Config struct
    cfg, err := mapToConfig(merged)
    if err != nil {
        return nil, fmt.Errorf("failed to unmarshal merged config: %w", err)
    }

    if err := cfg.Validate(); err != nil {
        return nil, fmt.Errorf("invalid config after merge: %w", err)
    }

    return cfg, nil
}

// loadSingleFile loads a single config file without layering
func loadSingleFile(path string) (*Config, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return nil, fmt.Errorf("failed to read config: %w", err)
    }

    var cfg Config
    if err := yaml.Unmarshal(data, &cfg); err != nil {
        return nil, fmt.Errorf("failed to parse config: %w", err)
    }

    if err := cfg.Validate(); err != nil {
        return nil, fmt.Errorf("invalid config: %w", err)
    }

    return &cfg, nil
}

// loadYAMLFile reads a YAML file into a map
func loadYAMLFile(path string) (map[string]any, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return nil, err
    }

    var m map[string]any
    if err := yaml.Unmarshal(data, &m); err != nil {
        return nil, err
    }

    return m, nil
}

// builtinDefaults returns hardcoded default values
func builtinDefaults() map[string]any {
    return map[string]any{
        "settings": map[string]any{
            "baseSpacing": 8,
        },
    }
}

// deepMerge merges override into base recursively.
// - Objects: merge recursively
// - Arrays: override replaces base
// - null: removes key from result
// - Scalars: override wins
func deepMerge(base, override map[string]any) map[string]any {
    result := make(map[string]any)

    // Copy base
    for k, v := range base {
        result[k] = v
    }

    // Apply overrides
    for k, v := range override {
        // null removes the key
        if v == nil {
            delete(result, k)
            continue
        }

        baseVal, exists := result[k]
        if !exists {
            result[k] = v
            continue
        }

        // If both are maps, merge recursively
        baseMap, baseIsMap := baseVal.(map[string]any)
        overrideMap, overrideIsMap := v.(map[string]any)
        if baseIsMap && overrideIsMap {
            result[k] = deepMerge(baseMap, overrideMap)
        } else {
            // Override wins (including arrays)
            result[k] = v
        }
    }

    return result
}

// mapToConfig converts a map[string]any to Config struct
func mapToConfig(m map[string]any) (*Config, error) {
    // Re-serialize to YAML then deserialize to struct
    // This leverages yaml struct tags for proper mapping
    data, err := yaml.Marshal(m)
    if err != nil {
        return nil, err
    }

    var cfg Config
    if err := yaml.Unmarshal(data, &cfg); err != nil {
        return nil, err
    }

    return &cfg, nil
}

func formatSearchedDirs(dirs []string) string {
    var result string
    for _, d := range dirs {
        result += fmt.Sprintf("  - %s/thegrid/config.yaml\n", d)
    }
    return result
}
```

### Swift Server (`Sources/GridServer/XDG.swift`)

```swift
import Foundation

enum XDG {
    static var configHome: String {
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !env.isEmpty {
            return env
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.config"
    }

    /// Returns validated config dirs, filtering out empty segments and relative paths
    static var configDirs: [String] {
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_DIRS"], !env.isEmpty {
            let dirs = env.split(separator: ":").compactMap { segment -> String? in
                let path = String(segment)
                // Skip empty segments and relative paths
                guard !path.isEmpty, path.hasPrefix("/") else { return nil }
                return path
            }
            if !dirs.isEmpty {
                return dedup(dirs)
            }
        }
        #if os(macOS)
        return ["/etc/xdg", "/opt/homebrew/etc", "/usr/local/etc"]
        #else
        return ["/etc/xdg"]
        #endif
    }

    static var stateHome: String {
        if let env = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !env.isEmpty {
            return env
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state"
    }

    /// Find config files in merge order (system -> user).
    /// Logs warnings for permission errors, silently skips missing files.
    static func findConfigFiles(app: String, filename: String) async -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default

        // System dirs (reverse order so first in XDG_CONFIG_DIRS wins)
        for dir in configDirs.reversed() {
            let path = "\(dir)/\(app)/\(filename)"
            guard !seen.contains(path) else { continue }
            seen.insert(path)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    paths.append(path)
                }
            } else if let error = checkAccessError(path: path) {
                await JSONLogger.shared.log("cfg.skip", msg: "cannot access file",
                    data: ["path": path, "err": error])
            }
        }

        // User config
        let userPath = "\(configHome)/\(app)/\(filename)"
        if !seen.contains(userPath) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: userPath, isDirectory: &isDir) {
                if !isDir.boolValue {
                    paths.append(userPath)
                }
            } else if let error = checkAccessError(path: userPath) {
                await JSONLogger.shared.log("cfg.skip", msg: "cannot access file",
                    data: ["path": userPath, "err": error])
            }
        }

        return paths
    }

    /// Check if a path has an access error (not just missing)
    private static func checkAccessError(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            _ = try url.checkResourceIsReachable()
            return nil
        } catch let error as NSError {
            // ENOENT = file doesn't exist, that's fine
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return nil
            }
            return error.localizedDescription
        }
    }

    private static func dedup(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}
```

### Swift Server (`Sources/GridServer/DeepMerge.swift`) - New File

```swift
import Foundation

/// Deep merge two dictionaries with XDG config semantics:
/// - Objects: merge recursively
/// - Arrays: override replaces base
/// - NSNull/nil: removes key from result
/// - Scalars: override wins
func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
    var result = base

    for (key, overrideValue) in override {
        // null/NSNull removes the key
        if overrideValue is NSNull {
            result.removeValue(forKey: key)
            continue
        }

        guard let baseValue = result[key] else {
            result[key] = overrideValue
            continue
        }

        // If both are dictionaries, merge recursively
        if let baseDict = baseValue as? [String: Any],
           let overrideDict = overrideValue as? [String: Any] {
            result[key] = deepMerge(baseDict, overrideDict)
        } else {
            // Override wins (including arrays)
            result[key] = overrideValue
        }
    }

    return result
}
```

### Swift Server (`BFDConfig.swift` changes)

```swift
enum BFDError: Error {
    case noConfigFound(searchedPaths: [String])
    case parseError(path: String, underlying: Error)
}

extension BFDConfig {
    /// Load config using XDG resolution with layered merging.
    /// This is the primary entry point for normal operation.
    static func load() async throws -> BFDConfig {
        let files = await XDG.findConfigFiles(app: "thegrid", filename: "bfd.yaml")

        // Log resolution
        await JSONLogger.shared.log("cfg.resolve", data: [
            "xdg_config_home": XDG.configHome,
            "xdg_config_dirs": XDG.configDirs,
            "files_found": files
        ])

        var merged: [String: Any] = [:]

        // Merge each file in order (system -> user)
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            guard let dict = try Yams.load(yaml: String(data: data, encoding: .utf8) ?? "") as? [String: Any] else {
                continue
            }
            merged = deepMerge(merged, dict)
            await JSONLogger.shared.log("cfg.merge", data: ["path": file])
        }

        // Apply .local.yaml overlay (highest priority)
        let localPath = "\(XDG.configHome)/thegrid/bfd.local.yaml"
        if FileManager.default.fileExists(atPath: localPath) {
            let localData = try Data(contentsOf: URL(fileURLWithPath: localPath))
            if let localDict = try Yams.load(yaml: String(data: localData, encoding: .utf8) ?? "") as? [String: Any] {
                merged = deepMerge(merged, localDict)
                await JSONLogger.shared.log("cfg.merge", data: ["path": localPath, "layer": "local"])
            }
        }

        // No config found at all
        if files.isEmpty && !FileManager.default.fileExists(atPath: localPath) {
            var searched = XDG.configDirs.map { "\($0)/thegrid/bfd.yaml" }
            searched.append("\(XDG.configHome)/thegrid/bfd.yaml")
            throw BFDError.noConfigFound(searchedPaths: searched)
        }

        // Convert merged dict to BFDConfig
        let yaml = try Yams.dump(object: merged)
        return try YAMLDecoder().decode(BFDConfig.self, from: yaml)
    }

    /// Load config from explicit path (no XDG resolution, no layering).
    /// Use this when user provides --config flag.
    static func load(from path: String) throws -> BFDConfig {
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let data = try Data(contentsOf: url)
        let decoder = YAMLDecoder()
        return try decoder.decode(BFDConfig.self, from: data)
    }
}
```

## CLI Debugging Commands

New `thegrid config` subcommand:

```bash
# Show which files would be loaded (without loading)
$ thegrid config sources
XDG_CONFIG_HOME: /Users/r/.config
XDG_CONFIG_DIRS: /etc/xdg:/opt/homebrew/etc:/usr/local/etc

Config sources (in merge order):
  1. /opt/homebrew/etc/thegrid/config.yaml (system)
  2. /Users/r/.config/thegrid/config.yaml (user)
  3. /Users/r/.config/thegrid/config.local.yaml (local)

# Show final merged config as YAML
$ thegrid config show

# Validate config (loads and validates without running)
$ thegrid config validate
Config valid (3 sources merged)
```

Note: The `origin` subcommand (showing which file a specific value came from) is deferred to a future version as it requires significant additional complexity to track provenance through the merge process.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| No config files found | Error with list of all paths checked |
| File not found | Silent skip (normal case) |
| Permission denied | Log warning, skip file, continue |
| Other access error | Log warning, skip file, continue |
| YAML parse error | Fail immediately with file path and error |
| Validation failure | Fail after merge, list all sources |

**Error message examples:**

```
Error: no config found; searched:
  - /Users/r/.config/thegrid/config.yaml
  - /etc/xdg/thegrid/config.yaml
  - /opt/homebrew/etc/thegrid/config.yaml
  - /usr/local/etc/thegrid/config.yaml

Error: failed to parse /etc/xdg/thegrid/config.yaml: yaml: line 12: mapping values not allowed

Error: invalid config after merge: settings.baseSpacing must be > 0
  Sources merged:
    - /opt/homebrew/etc/thegrid/config.yaml
    - /Users/r/.config/thegrid/config.yaml
```

## Logging

```jsonl
{"ts":1702840000,"ev":"cfg.resolve","data":{"xdg_config_home":"~/.config","xdg_config_dirs":["/etc/xdg","/opt/homebrew/etc"],"files_found":["~/.config/thegrid/config.yaml"]}}
{"ts":1702840001,"ev":"cfg.merge","data":{"path":"~/.config/thegrid/config.yaml"}}
{"ts":1702840002,"ev":"cfg.skip","msg":"cannot access file","data":{"path":"/etc/xdg/thegrid/config.yaml","err":"permission denied"}}
{"ts":1702840003,"ev":"cfg.merge","data":{"path":"~/.config/thegrid/config.local.yaml","layer":"local"}}
```

## Migration

**Backwards compatibility**: Existing configs at `~/.config/thegrid/` continue to work unchanged. This path is already the XDG default.

**No user action required**: Users only see different behavior if:
1. They set `$XDG_CONFIG_HOME` to a non-default location
2. System configs exist at `/etc/xdg/thegrid/` or `/opt/homebrew/etc/thegrid/`

Most users have neither, so behavior is identical.

**Homebrew formula** (future):
```ruby
def install
  # Install binary...

  # Install default config to system location
  (etc/"thegrid").install "config.default.yaml" => "config.yaml"
end
```

**Testing the migration:**
```bash
# Verify XDG resolution is working
$ thegrid config sources

# Verify your config still loads correctly
$ thegrid config validate

# Check merged result
$ thegrid config show
```

## Implementation Tasks

1. Create `internal/xdg` package in Go CLI
   - `ConfigHome()`, `ConfigDirs()`, `StateHome()`
   - `FindConfigFiles()` with permission error logging
   - Path validation and deduplication

2. Create `internal/config/loader.go` in Go CLI
   - `loadWithXDG()` - full XDG resolution
   - `loadSingleFile()` - explicit path (no layering)
   - `deepMerge()` with null-removes-key semantic
   - `builtinDefaults()` for hardcoded defaults

3. Create `Sources/GridServer/XDG.swift`
   - Same API as Go version
   - Async `findConfigFiles()` for proper logging

4. Create `Sources/GridServer/DeepMerge.swift`
   - `deepMerge()` function with NSNull handling

5. Update `BFDConfig.swift`
   - Add async `load()` for XDG resolution
   - Keep `load(from:)` for explicit paths
   - Add `BFDError` enum with descriptive errors

6. Add `thegrid config` subcommand
   - `sources` - show XDG paths and found files
   - `show` - output merged config as YAML
   - `validate` - load and validate without running

7. Update `CLAUDE.md`
   - Document XDG environment variables
   - Update config path references
   - Add `thegrid config` command examples

8. Unit tests (3-5 targeted tests)
   - Default XDG paths (no env vars)
   - Custom `$XDG_CONFIG_HOME`
   - Custom `$XDG_CONFIG_DIRS` with multiple paths
   - Deep merge behavior (null removes, array replace, nested merge)
   - Path validation (relative paths filtered)
