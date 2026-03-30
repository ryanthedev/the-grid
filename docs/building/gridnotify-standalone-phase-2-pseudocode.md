# Pseudocode: Phase 2 - Build system and deployment

## File: Makefile

### New variables (add after existing ENTITLEMENTS/APP_BUNDLE/DEPLOY_LOCATION)

```
NOTIFY_ENTITLEMENTS := $(CURDIR)/grid-notify/grid-notify.entitlements
NOTIFY_APP_BUNDLE := grid-notify/.build/debug/GridNotify.app
NOTIFY_DEPLOY_LOCATION := $(HOME)/.local/state/thegrid/GridNotify.app
```

### New targets

#### `notify` - debug build (mirrors `server`)
```
notify:
  echo "Building grid-notify..."
  cd grid-notify && swift build
```

#### `notify-universal` - universal binary (mirrors `server-universal`)
```
notify-universal:
  echo "Building grid-notify (universal binary)..."
  cd grid-notify && swift build -c release --arch arm64 --arch x86_64
  verify: file grid-notify/.build/apple/Products/Release/GridNotify contains "universal binary"
  if not: error and exit
```

#### `notify-app-bundle` - release app bundle (mirrors `app-bundle`)
```
notify-app-bundle: depends on notify-universal
  echo "Creating GridNotify.app bundle..."
  rm -rf dist/GridNotify.app
  mkdir -p dist/GridNotify.app/Contents/MacOS
  mkdir -p dist/GridNotify.app/Contents/Resources
  cp grid-notify/.build/apple/Products/Release/GridNotify -> dist/GridNotify.app/Contents/MacOS/grid-notify
  cp grid-notify/Info.plist -> dist/GridNotify.app/Contents/
  sed VERSION_PLACEHOLDER -> $(VERSION) in dist/GridNotify.app/Contents/Info.plist
  verify version substitution worked (grep)
  codesign binary with NOTIFY_ENTITLEMENTS
  codesign .app bundle with NOTIFY_ENTITLEMENTS
  codesign --verify --verbose
  codesign -dv (show first 5 lines)
  echo "GridNotify.app created"
```

NOTE: The binary in SPM is named `GridNotify` but in the .app bundle CFBundleExecutable
is `grid-notify`, so we copy `GridNotify` -> `grid-notify` in the MacOS dir.

#### `notify-dev` - debug app bundle + deploy (mirrors the dev target pattern for grid-server)
```
notify-dev: depends on notify
  echo "Creating debug GridNotify.app bundle..."
  mkdir -p $(NOTIFY_APP_BUNDLE)/Contents/MacOS
  mkdir -p $(NOTIFY_APP_BUNDLE)/Contents/Resources
  cp grid-notify/.build/debug/GridNotify -> $(NOTIFY_APP_BUNDLE)/Contents/MacOS/grid-notify
  cp grid-notify/Info.plist -> $(NOTIFY_APP_BUNDLE)/Contents/
  codesign binary with NOTIFY_ENTITLEMENTS
  codesign .app bundle with NOTIFY_ENTITLEMENTS
  echo "Debug GridNotify.app built"
  echo "Deploying to $(NOTIFY_DEPLOY_LOCATION)..."
  mkdir -p parent of NOTIFY_DEPLOY_LOCATION
  rm -rf $(NOTIFY_DEPLOY_LOCATION)
  cp -R $(NOTIFY_APP_BUNDLE) -> $(NOTIFY_DEPLOY_LOCATION)
  echo "GridNotify deployed"
```

### Modified targets

#### Update `build` to include notify
```
build: server cli notify
```

#### Update `dev` to include notify-dev
```
dev: server viewer notify-dev
  ... existing server bundle steps unchanged ...
  (notify-dev runs as prerequisite, building and deploying GridNotify.app)
```

Wait -- `dev` currently bundles grid-server inline (not as a separate target).
Better approach: keep `dev` doing its server work, add `notify-dev` as a prerequisite.

Actually, looking more carefully: `dev` depends on `server viewer` and then does
the bundle/sign/deploy inline. We should add `notify-dev` as a dependency of `run`,
not `dev`, to keep concerns separate. But we also want `make dev` to build everything.

Revised approach:
- `dev` adds `notify-dev` as a prerequisite: `dev: server viewer notify-dev`
- `dev` body stays the same (only handles server bundle)
- `notify-dev` is a separate target that handles notify bundle
- `run` calls `dev install-dev` which transitively builds everything

#### Update `run` to kill and relaunch grid-notify
```
run: dev install-dev
  kill grid-server processes (existing)
  kill grid-notify processes: pkill -9 -f GridNotify.app (or grid-notify)
  sleep 0.5
  clear state/logs/cache (existing)
  restart thegrid-dev service (existing - grid-server)
  launch grid-notify: open $(NOTIFY_DEPLOY_LOCATION)
  echo done
```

#### Update `dist-universal` to include GridNotify.app
```
dist-universal: app-bundle notify-app-bundle cli-universal viewer-universal
  ... existing steps ...
  add: cp -R dist/GridNotify.app dist/thegrid-$(VERSION)/
  update FORMULA_INSTALL to include GridNotify.app install_symlink
  update verify to also check GridNotify.app binary
```

#### Update `.PHONY` line
Add: notify notify-dev notify-universal notify-app-bundle notify-dev

#### Update `help` text
Add grid-notify targets to help output.

### Summary of changes to Makefile

1. Add NOTIFY_ENTITLEMENTS, NOTIFY_APP_BUNDLE, NOTIFY_DEPLOY_LOCATION variables
2. Add `notify` target (debug build)
3. Add `notify-universal` target (universal build)
4. Add `notify-app-bundle` target (release .app bundle in dist/)
5. Add `notify-dev` target (debug .app bundle + deploy)
6. Update `build` prereqs: add `notify`
7. Update `dev` prereqs: add `notify-dev`
8. Update `run` body: kill grid-notify, launch after restart
9. Update `dist-universal` prereqs and body: include GridNotify.app
10. Update `.PHONY` and `help`
