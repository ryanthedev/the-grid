# ADR-002: BFD Shell Wrapper for Portable PATH Configuration

**Date:** 2025-12-22
**Status:** Accepted

## Context

BFD (Built-in Focus Direction) executes shell commands for hotkeys. These commands often invoke user scripts located in `~/.config/bin` or `~/.local/bin`. When thegrid runs as a launchd service, it has a limited PATH defined in its plist file.

The problem: **launchd plist files cannot use environment variable expansion** (e.g., `$HOME`). This means PATH entries must use absolute paths like `/Users/r/.local/bin`, making the plist user-specific.

We wanted to:
1. Allow BFD commands to find user scripts (like `services`, `dalauncher`)
2. Minimize hardcoded user-specific paths
3. Keep bfd.yaml portable across machines

## Decision

**Create a shell wrapper script (`bfd-shell`) that sets up PATH before executing commands.**

The solution has three parts:

### 1. `scripts/bfd-shell` wrapper
```bash
#!/bin/zsh
export PATH="$HOME/.config/bin:$HOME/.local/bin:$PATH"
exec /bin/zsh -c "$*"
```

This script uses `$HOME` (which works in shell scripts) to add user bin directories to PATH.

### 2. `bfd.yaml` configuration
```yaml
shell: bfd-shell
```

BFD uses `bfd-shell` instead of `/bin/zsh` directly.

### 3. Service plist PATH
The plist only needs `~/.local/bin` in PATH (so BFD can find `bfd-shell`). The wrapper handles adding other directories.

```xml
<string>/Users/r/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
```

## Consequences

### Positive

1. **bfd.yaml is portable** - Uses `bfd-shell` instead of hardcoded paths
2. **Commands work naturally** - `services stop thegrid-dev` just works
3. **Single point of PATH configuration** - Add new directories to bfd-shell
4. **Minimal plist modification** - Only one user-specific PATH entry needed

### Negative

1. **Plist still has one hardcoded path** - `/Users/r/.local/bin` is unavoidable since plists don't expand `$HOME`. This is acceptable because the plist already has other user-specific paths (binary location, working directory, log paths).

2. **Extra indirection** - Commands go through bfd-shell → zsh instead of directly to zsh. The overhead is negligible.

3. **Installation required** - `make install-scripts` must be run to symlink bfd-shell to `~/.local/bin`.

## Alternatives Considered

### Put all paths in plist
Hardcode all user bin directories in the plist PATH. Rejected because:
- Makes plist even more user-specific
- Changes to PATH require plist edit + service restart
- Harder to keep in sync across machines

### Source .zshrc in commands
Have BFD run `source ~/.zshrc && command`. Rejected because:
- Slow (full shell initialization per command)
- Side effects from full rc file
- Fragile if rc file has errors

### Template/generate the plist
Use a script to generate the plist with expanded paths. Rejected because:
- Adds build complexity
- Plist would need regeneration when HOME changes
- Overkill for this problem

## Notes

The `bfd-shell` wrapper is installed via `make install-scripts`, which symlinks it to `~/.local/bin/bfd-shell`. This is the same mechanism used for other thegrid utility scripts.
