# Grid Scripting Addition

This directory contains the Grid Scripting Addition (SA), which enables window-to-space movement on modern macOS versions (12.7+, 13.6+, 14.5+, 15+).

## Why is this needed?

Apple restricts the `SLSMoveWindowsToManagedSpace` SkyLight API on modern macOS versions. This API only works when called from within privileged process contexts like `Dock.app`.

The Grid SA solves this by:
1. Loading code into Dock.app's process space
2. Running a Unix socket server inside Dock
3. Executing window move operations with proper privileges

This is the same approach used by [yabai](https://github.com/koekeishiya/yabai).

## Prerequisites

### System Integrity Protection (SIP)

You **must partially disable SIP** to install scripting additions. Specifically, you need to disable filesystem protections.

**⚠️ Warning:** Disabling SIP reduces system security. Only do this if you understand the implications.

#### Steps to disable SIP:

1. **Reboot into Recovery Mode:**
   - Intel Mac: Restart and hold `Cmd + R` during boot
   - Apple Silicon Mac: Shut down, then press and hold the power button until "Loading startup options" appears

2. **Open Terminal** from the Utilities menu

3. **Disable filesystem protections:**
   ```bash
   csrutil enable --without fs --without debug
   ```

4. **Reboot normally**

5. **Verify SIP status:**
   ```bash
   csrutil status
   ```

   You should see:
   ```
   System Integrity Protection status: enabled (Custom Configuration).

   Configuration:
       Apple Internal: enabled
       Kext Signing: enabled
       Filesystem Protections: disabled  ← Important!
       Debugging Restrictions: disabled  ← Important!
       ...
   ```

## Installation

### 1. Build the Scripting Addition

From the `GridSA` directory:

```bash
cd GridSA
make
```

This creates `build/grid-sa.osax`.

### 2. Install to System

```bash
make install
```

This will:
- Copy `grid-sa.osax` to `/Library/ScriptingAdditions/`
- Require sudo password

### 3. Restart Dock

```bash
killall Dock
```

The Dock will restart automatically and load the Grid SA.

### 4. Verify Installation

```bash
make check
```

Expected output:
```
✓ Socket exists: /tmp/grid-sa_<username>.socket
✓ Grid SA is loaded and running
```

## Usage

Once installed, GridServer will automatically detect and use the scripting addition when moving windows to spaces on modern macOS.

No code changes needed - the SA is used transparently when available.

## Troubleshooting

### Socket not found

```bash
make check
```

If you see "Socket not found":

1. **Check installation:**
   ```bash
   ls -la /Library/ScriptingAdditions/grid-sa.osax
   ```

2. **Check Dock logs:**
   ```bash
   make logs
   ```

   Look for `[GridSA]` messages:
   - `Loaded into process: Dock` - SA loaded successfully
   - `Listening on socket: /tmp/grid-sa_...` - Server started
   - If you don't see these, the SA didn't load

3. **Common issues:**
   - **SIP not properly disabled:** Run `csrutil status` to verify
   - **Dock not restarted:** Run `killall Dock`
   - **Architecture mismatch:** The SA is built for both Intel and Apple Silicon

### SA loads but window move fails

Check GridServer logs when attempting a window move:

```bash
# Run grid-server and watch logs
.build/debug/grid-server
```

Look for:
- `✓ Scripting Addition available` - SA detected
- `🎯 Moving window via SA` - Attempting move
- `✓ Window moved successfully via SA` - Success
- `❌ SA move API failed` - Communication error
- `❌ SA move verification failed` - Move executed but window didn't move

### View detailed logs

```bash
# Console.app method
open /Applications/Utilities/Console.app
# Filter for: process:Dock AND GridSA

# Or command line:
log show --predicate 'process == "Dock" AND eventMessage CONTAINS "GridSA"' \
         --last 10m --style compact
```

### Uninstall

```bash
make uninstall
killall Dock
```

This removes the SA from `/Library/ScriptingAdditions/` and restarts Dock.

## Development

### Building

```bash
make              # Build the SA
make clean        # Clean build artifacts
make install      # Build and install
make uninstall    # Uninstall
make check        # Check if SA is loaded
make logs         # View recent logs
```

### Architecture

**GridSA Components:**

1. **grid-sa.m** - Main SA implementation
   - `osax_load()` - Constructor, runs when Dock loads the SA
   - `daemon_thread_proc()` - Unix socket server
   - `handle_window_to_space()` - Single window move
   - `handle_window_list_to_space()` - Batch window move

2. **Info.plist** - Bundle metadata

3. **Makefile** - Build system

**Communication Protocol:**

The SA uses a simple binary protocol over Unix domain sockets:

```
Request:  [opcode:1] [payload:N]
Response: [success:1]  (1 = success, 0 = failure)
```

**Opcodes:**
- `0x01` - Handshake (connection test)
- `0x13` - Move single window to space
- `0x12` - Move multiple windows to space

**Move Single Window Payload:**
```
[opcode:1][space_id:8][window_id:4]
```

**Move Multiple Windows Payload:**
```
[opcode:1][space_id:8][count:4][window_id_1:4][window_id_2:4]...
```

All multi-byte values are little-endian.

### Swift Client

The Swift client is located at `Sources/GridServer/ScriptingAdditionClient.swift`.

It handles:
- SA availability detection
- Socket communication
- Binary protocol encoding/decoding
- Error handling

Integration in `WindowManipulator` automatically uses SA when available on modern macOS.

## Security Considerations

**Disabling SIP reduces system security.** Be aware:

- Filesystem protections prevent unauthorized modifications to system files
- Debugging restrictions protect against certain exploits
- Only disable these if you trust all applications you run

**The Grid SA itself:**
- Only loads into Dock.app (checks process name)
- Only accepts connections from the current user (Unix socket permissions)
- Only executes window management operations
- Does not modify system files or execute arbitrary code

## References

- [yabai Scripting Addition](https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(latest-release)#configure-scripting-addition) - Similar implementation
- [SkyLight API Documentation](https://github.com/koekeishiya/yabai/blob/master/doc/yabai.asciidoc#window-commands) - Private API reference
- [Apple SIP Documentation](https://support.apple.com/en-us/HT204899) - Official SIP guide

## License

Same as parent project.
