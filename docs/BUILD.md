# Building TheGrid

## Prerequisites

- macOS 13.0 or later
- Xcode Command Line Tools: `xcode-select --install`
- Swift 5.9+
- Go 1.21+
- jq (optional, for log viewing): `brew install jq`

## Quick Start

```bash
# One-time setup: create code signing certificate
make setup-signing

# Build and run
make run
```

## Overview

TheGrid consists of two components:

| Component | Language | Output |
|-----------|----------|--------|
| grid-server | Swift | `GridServer.app` bundle |
| grid-cli | Go | `thegrid` binary |

The server requires an `.app` bundle (not a bare binary) because macOS TCC tracks permissions by bundle identifier (`CFBundleIdentifier` in Info.plist), which only exists in app bundles.

## Code Signing

### Why It Matters

macOS TCC (Transparency, Consent, and Control) associates Accessibility permissions with an app's **code signature**. With ad-hoc signing (`codesign -s -`), every build gets a new signature, requiring you to re-grant permissions each time.

Using a stable signing certificate means TCC recognizes the app across rebuilds and remembers your permission grant.

### Setup (One-Time)

```bash
make setup-signing
```

This creates a self-signed certificate named `thegrid-dev` in your login keychain. Verify it exists:

```bash
security find-identity -v -p codesigning | grep thegrid-dev
```

You should see something like:
```
1) 90DCCA24BBD1B0443E92825E8CA948E35D9CD689 "thegrid-dev"
```

The certificate is valid for 10 years. After expiration, run `make setup-signing` again.

### How It Works

The build process:

1. Compiles `grid-server` binary
2. Creates `GridServer.app` bundle structure
3. Signs with `thegrid-dev` certificate + entitlements (using `-f` to replace existing signatures)
4. Copies to build output

The entitlements file (`grid-server/thegrid.entitlements`) disables app sandbox, which is required for Accessibility API access:

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
```

## Running the Server

### With Service Manager

The `make run` target uses `services` (a launchd wrapper) to restart the server:

```bash
make run
```

### Manual Start/Stop

```bash
# Start manually
./grid-server/.build/debug/GridServer.app/Contents/MacOS/grid-server

# Stop
pkill -f grid-server
```

## Build Targets

### Development

```bash
# Build debug app bundle + CLI
make dev

# Build and restart the thegrid-dev service
make run

# Just build the server
make server

# Just build the CLI
make cli
```

### Release

```bash
# Universal binary distribution (arm64 + x86_64)
make dist-universal

# Single-arch distribution (current machine)
make dist
```

### Testing

```bash
# Run all tests
make test

# Server tests only
make server-test

# CLI tests only
make cli-test
```

## Build Outputs

| Target | Output Location |
|--------|-----------------|
| `make dev` | `grid-server/.build/debug/GridServer.app` |
| `make cli` | `grid-cli/bin/thegrid` |
| `make app-bundle` | `dist/GridServer.app` (release .app bundle) |
| `make dist-universal` | `dist/thegrid-$(VERSION)-darwin-universal.tar.gz` |

Note: Debug builds (`make dev`) do not substitute `VERSION_PLACEHOLDER` in Info.plist. Release builds (`make dist-universal`) automatically replace it with the version from the `VERSION` file.

## Accessibility Permissions

### First Run

The first time you run GridServer.app after setup, macOS will prompt for Accessibility permission. Grant it in:

**System Settings → Privacy & Security → Accessibility**

### After Granting

Subsequent builds won't prompt again because the signature (from `thegrid-dev` certificate) remains consistent.

### Troubleshooting Permissions

If permissions get stuck or confused:

```bash
# Reset TCC permissions for TheGrid
make reset-accessibility

# Then rebuild and run
make run
```

This runs `tccutil reset Accessibility com.thegrid.server` which clears the cached permission state.

### Manual Reset

If the make target doesn't work:

```bash
# Reset via tccutil
tccutil reset Accessibility com.thegrid.server

# Or manually in System Settings:
# 1. Open System Settings → Privacy & Security → Accessibility
# 2. Find GridServer and remove it
# 3. Run: make run
# 4. Grant permission when prompted
```

## Verifying Builds

### Check Signature

```bash
# Show signing info
codesign -dv grid-server/.build/debug/GridServer.app

# Verify signature is valid
codesign --verify --verbose grid-server/.build/debug/GridServer.app

# Show embedded entitlements
codesign -d --entitlements - grid-server/.build/debug/GridServer.app
```

Expected output:
```
Authority=thegrid-dev
Identifier=com.thegrid.server
```

### Check Server Status

```bash
# Ping the server
./grid-cli/bin/thegrid ping

# Check if server process is running
pgrep -f grid-server

# View recent server logs
tail -20 ~/.local/state/thegrid/thegrid-server.json | jq -r '.ev'
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODESIGN_IDENTITY` | `thegrid-dev` | Certificate name for signing |

Override for CI or different certificates:

```bash
CODESIGN_IDENTITY="My Other Cert" make dev
```

## Troubleshooting

### "thegrid-dev: no identity found"

The signing certificate doesn't exist. Run:

```bash
make setup-signing
```

### "errSecInternalComponent" or signing fails

Your keychain may be locked. Unlock it:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

### Permission prompt appears on every build

The certificate isn't being used consistently. Verify:

```bash
codesign -dvvv grid-server/.build/debug/GridServer.app 2>&1 | grep Authority
```

Should show `Authority=thegrid-dev`. If it shows `Authority=` (empty) or ad-hoc, the certificate isn't being found.

### "GridServer.app is damaged" or won't open

The signature is invalid. Rebuild:

```bash
make clean
make dev
```

### Server crashes immediately

Check logs:

```bash
tail -50 ~/.local/state/thegrid/thegrid-server.json
```

Common causes:
- Another instance already running on the socket
- Missing Accessibility permission
- Corrupted state file

### Server runs but Accessibility doesn't work

Make sure you're running the binary from INSIDE the app bundle:

```bash
# Correct - run from app bundle
./grid-server/.build/debug/GridServer.app/Contents/MacOS/grid-server

# Wrong - accessibility will fail
./grid-server/.build/debug/grid-server
```

The binary must be launched from the signed `.app` bundle for TCC to recognize it.

## File Locations

| File | Purpose |
|------|---------|
| `VERSION` | Project version number (used in release builds) |
| `grid-server/thegrid.entitlements` | Entitlements for code signing |
| `grid-server/Info.plist` | App bundle metadata |
| `scripts/create-dev-certificate.sh` | Creates signing certificate |
| `scripts/reset-accessibility.sh` | Resets TCC permissions |
| `~/.local/state/thegrid/` | Runtime state and logs |
| `~/.config/thegrid/config.yaml` | User configuration |
