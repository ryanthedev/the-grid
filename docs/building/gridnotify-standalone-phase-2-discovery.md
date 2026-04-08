# Discovery: Phase 2 - Build system and deployment

## Current State

### Existing Makefile pattern (grid-server)
The Makefile at repo root has these relevant targets for grid-server:

1. **`server`** - Debug build: `cd grid-server && swift build`
2. **`server-release`** - Release build: `cd grid-server && swift build -c release`
3. **`server-universal`** - Universal binary: `swift build -c release --arch arm64 --arch x86_64`
4. **`dev`** - Debug app bundle: builds debug, creates `GridServer.app` structure, signs, deploys to `~/.local/state/thegrid/GridServer.app`
5. **`app-bundle`** - Release app bundle: builds universal, creates `dist/GridServer.app`, signs, verifies
6. **`run`** - Full cycle: calls `dev`, `install-dev`, kills processes, clears state, restarts service
7. **`dist-universal`** - Distribution tarball: includes `GridServer.app`, CLI, viewer

### App bundle structure
```
GridServer.app/
  Contents/
    MacOS/grid-server          (the binary)
    Info.plist                 (with VERSION_PLACEHOLDER substituted)
    Resources/                 (empty but created)
```

### Code signing
- Identity: `thegrid-dev` (self-signed dev cert)
- Entitlements: `grid-server/thegrid.entitlements` (app-sandbox=false)
- Signs both the binary and the .app bundle
- Verified with `codesign --verify --verbose`

### grid-notify package (Phase 1 output)
- Location: `grid-notify/`
- SPM package, executable target name: `GridNotify`
- Binary output: `grid-notify/.build/debug/GridNotify`
- Info.plist: `grid-notify/Info.plist` (has VERSION_PLACEHOLDER)
- Entitlements: `grid-notify/grid-notify.entitlements` (app-sandbox=false)
- Bundle ID: `com.thegrid.notify`

### Key variables in Makefile
- `VERSION` - from `VERSION` file (currently 0.4.5)
- `COMMIT` - from git rev-parse HEAD
- `CODESIGN_IDENTITY` - defaults to `thegrid-dev`
- `ENTITLEMENTS` - points to `$(CURDIR)/grid-server/thegrid.entitlements`
- `APP_BUNDLE` - `grid-server/.build/debug/GridServer.app`
- `DEPLOY_LOCATION` - `$(HOME)/.local/state/thegrid/GridServer.app`

### What needs to be added
1. `notify` target - build grid-notify debug
2. `notify-universal` target - build universal binary
3. `notify-app-bundle` target - create release GridNotify.app in dist/
4. `notify-dev` target - create debug GridNotify.app, sign, deploy
5. Update `dev` to depend on `notify-dev` (or make `run` call both)
6. Update `run` to kill grid-notify, deploy both, relaunch both
7. Update `dist-universal` to include GridNotify.app
8. Update `build` to include notify
9. Add notify-specific variables (NOTIFY_ENTITLEMENTS, NOTIFY_APP_BUNDLE, NOTIFY_DEPLOY_LOCATION)

### Process management for grid-notify
- grid-server is managed by `services restart thegrid-dev` (launchd)
- grid-notify should be launched directly after deployment (not via launchd)
- Kill with `pkill -f grid-notify` before redeployment
- Launch with `open ~/.local/state/thegrid/GridNotify.app`
