# Pseudocode: GridNotify Standalone App (Phase 1)

## Overview

Create GridNotify.app as a standalone macOS notification viewer at `grid-notify/`.
Adapt existing notification code from grid-server, removing all grid-server dependencies.

---

## 1. SPM Package [DW-1.1]

### grid-notify/Package.swift

```
swift-tools-version: 5.9
package name: "GridNotify"
platforms: macOS(.v13)

dependencies:
  - Yams (from: "5.0.0")

targets:
  - executableTarget "GridNotify"
    dependencies: [Yams]
    path: "Sources/GridNotify"

  - testTarget "GridNotifyTests"
    dependencies: ["GridNotify"]
    path: "Tests/GridNotifyTests"
```

No dependency on grid-server package targets.

---

## 2. Data Model [DW-1.3, DW-1.4, DW-1.5]

### Sources/GridNotify/Notification.swift

Copy verbatim from grid-server:
- GridNotificationPriority (enum, Codable, Comparable)
- GridNotificationAction (enum, Codable) -- keep all three cases (focusWindow, runShellCommand, openURL)
- GridNotification (struct, Codable, Identifiable)
- GridNotificationFilter (struct)
- GridNotificationStoreData (struct, Codable)

No changes needed. The model is self-contained.

---

## 3. XDG Paths [DW-1.1, DW-1.5, DW-1.6, DW-1.7]

### Sources/GridNotify/XDG.swift

Copy from grid-server/Sources/GridServer/XDG.swift.
One change: replace JSONLogger.shared.log calls in checkAccessError path with
the local jlog function (which will be defined in this package's JSONLogger.swift).

Same interface:
- XDG.configHome -> String
- XDG.configDirs -> [String]
- XDG.stateHome -> String
- XDG.findConfigFiles(app:filename:) async -> [String]

---

## 4. JSONL Logger [DW-1.7]

### Sources/GridNotify/CurrentSpan.swift

Copy verbatim from grid-server/Sources/GridServer/CurrentSpan.swift.
- enum CurrentSpan with @TaskLocal Span?
- traceId / spanId computed properties

### Sources/GridNotify/JSONLogger.swift

Adapt from grid-server/Sources/GridServer/JSONLogger.swift.

Changes:
- JSONLogWriter.filePath = "$stateHome/thegrid/thegrid-notify.json"
  (use XDG.stateHome instead of hardcoded home path)
- Everything else identical: batch writer, formatLine, escapeString, encodeData

Same interface:
- JSONLogWriter.shared.enqueue(line)
- JSONLogger.shared.log(ev, msg, data, tid, sid)
- jlog(ev, msg, data) convenience function
- Span struct with startChild / end

---

## 5. Notification Store [DW-1.5]

### Sources/GridNotify/NotificationStore.swift

Adapt from grid-server. Changes:

1. Remove `static let _shared` / `static var shared` singleton.
   Instead, instantiate in AppDelegate and pass through.

2. Replace `jlog(...)` calls with the local package's jlog function.
   (Same function signature, just different import -- no code change needed since
   jlog is a free function defined in our package's JSONLogger.swift.)

3. Keep all CRUD, query, bulk ops, trim, persist, flush, load methods.

4. Path: default init uses `"\(XDG.stateHome)/thegrid/notifications.json"`.
   Test init accepts explicit path.

No other changes. The actor is self-contained.

---

## 6. File/Pipe Watcher [DW-1.3]

### Sources/GridNotify/NotificationFileWatcher.swift

Adapt from grid-server. Changes:

1. Remove `NotificationPanelManager.shared.currentViewModel?.refreshNotifications()` calls.
   Replace with a callback: `var onNotification: (() -> Void)?`
   After adding to store, call `onNotification?()` on MainActor.

2. Replace: in processLine, the Task block becomes:
   ```
   let store = self.store
   let callback = self.onNotification
   Task {
       await store.add(notification)
       await MainActor.run {
           callback?()
       }
   }
   ```

3. Keep all fd management, EOF/reopen logic, line buffering, JSON parsing.

4. Constructor takes store + config (unchanged).

---

## 7. Source Config [DW-1.3, DW-1.6]

### Sources/GridNotify/NotificationSourceConfig.swift

Only keep NotificationWatcherConfig from grid-server:

```
struct NotificationWatcherConfig {
    let path: String        // empty = disabled
    let sourceLabel: String // default "pipe"
}
```

Drop EventNotificationRule, NotificationEventConfig (not needed without grid events).

---

## 8. Theme [DW-1.6]

### Sources/GridNotify/NotificationPanelTheme.swift

Copy verbatim from grid-server. No changes.

Same interface:
- NotificationPanelTheme struct with all color fields
- .default static instance
- init(from: [String: String]) for YAML hex dict
- parseHex / parseHexToNSColor private helpers

---

## 9. ViewModel [DW-1.4]

### Sources/GridNotify/NotificationPanelViewModel.swift

Adapt from grid-server. Changes:

1. Constructor takes `store: NotificationStore` (no change to signature).
   Remove any reference to NotificationStore.shared.

2. All vim keybinding logic stays identical:
   - j/k navigate, g/G first/last
   - d dismiss, x dismiss, p pin
   - +/- priority
   - V visual select, d/p in visual mode
   - / filter mode, Escape exit
   - Return execute action

3. No changes to refreshNotifications, buildFilter, updateStatusText,
   selectNext/Previous/First/Last, dismiss/pin/priority methods.

All methods operate on the injected `store` reference. No grid-server singletons.

---

## 10. Views [DW-1.2, DW-1.4]

### Sources/GridNotify/NotificationPanelViews.swift

Copy verbatim from grid-server. No changes.

All views are pure SwiftUI, bound to NotificationPanelViewModel via @ObservedObject.
No grid-server dependencies.

---

## 11. Window [DW-1.2, DW-1.4]

### Sources/GridNotify/NotificationPanelWindow.swift

Adapt from grid-server. Changes:

1. Replace executeNotificationAction to remove grid-server dependencies:
   - focusWindow: log warning "focusWindow not available in standalone mode", no-op
   - runShellCommand: keep as-is (Process launch)
   - openURL: keep as-is (NSWorkspace.shared.open)

2. Remove `NotificationPanelManager.shared.hide()` call before focusWindow.

3. Remove imports/references to StateManager, WindowManipulator, SLSMainConnectionID.

4. Keep all other window setup: .titled style mask, titlebar transparent,
   canBecomeKey, canBecomeMain, keyDown interception, hosting view.

---

## 12. YAML Config [DW-1.6]

### Sources/GridNotify/NotifyConfig.swift

New file. Loads `~/.config/thegrid/notify.yaml`.

```
struct NotifyConfig {
    var pipePath: String          // default: "$stateHome/thegrid/notify.pipe"
    var pipeSourceLabel: String   // default: "pipe"
    var maxCount: Int             // default: 0 (unlimited)
    var themeColors: [String: String]  // hex dict for theme override
}

// YAML structure:
// pipe:
//   path: "~/.local/state/thegrid/notify.pipe"
//   source_label: "pipe"
// max_count: 200
// theme:
//   background: "#121212"
//   accent: "#00BFFF"

private struct NotifyConfigYAML: Codable {
    var pipe: PipeYAML?
    var maxCount: Int?
    var theme: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case pipe
        case maxCount = "max_count"
        case theme
    }
}

private struct PipeYAML: Codable {
    var path: String?
    var sourceLabel: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case sourceLabel = "source_label"
    }
}

// Load function:
func loadNotifyConfig() -> NotifyConfig
    let configPath = "\(XDG.configHome)/thegrid/notify.yaml"
    guard FileManager.default.fileExists(atPath: configPath)
        else: return NotifyConfig() with defaults

    read file data
    decode YAML string with Yams.load(yaml:) -> [String: Any]
    re-encode to Data, decode as NotifyConfigYAML with YAMLDecoder

    map fields:
        pipePath = expand tilde in yaml.pipe?.path ?? default
        pipeSourceLabel = yaml.pipe?.sourceLabel ?? "pipe"
        maxCount = yaml.maxCount ?? 0
        themeColors = yaml.theme ?? [:]

    return config

// Tilde expansion:
func expandTilde(_ path: String) -> String
    if path.hasPrefix("~/"):
        return homeDir + path.dropFirst(1)
    return path
```

---

## 13. Info.plist [DW-1.1, DW-1.2]

### grid-notify/Info.plist

```xml
CFBundleExecutable: grid-notify
CFBundleIdentifier: com.thegrid.notify
CFBundleName: GridNotify
CFBundleDisplayName: GridNotify
CFBundlePackageType: APPL
CFBundleVersion: VERSION_PLACEHOLDER
CFBundleShortVersionString: VERSION_PLACEHOLDER
LSUIElement: false  (GridNotify IS visible, unlike grid-server)
NSHighResolutionCapable: true
```

No accessibility or screen capture usage descriptions needed.
GridNotify does not use AX APIs or CGWindowList.

---

## 14. Entitlements [DW-1.1]

### grid-notify/grid-notify.entitlements

```xml
com.apple.security.app-sandbox: false
```

Same as grid-server. Minimal entitlements.

---

## 15. Version.swift [DW-1.1]

### Sources/GridNotify/Version.swift

Hardcoded placeholder for Phase 1. Phase 2 Makefile integration will generate this.

```swift
let GridNotifyVersion = "0.1.0"
let GridNotifyCommit = "dev"
```

---

## 16. App Lifecycle [DW-1.2, DW-1.3, DW-1.5, DW-1.6, DW-1.7]

### Sources/GridNotify/main.swift

```
import AppKit

// Create and run NSApplication with our AppDelegate
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

### Sources/GridNotify/AppDelegate.swift

```
class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NotificationPanelWindow?
    private var viewModel: NotificationPanelViewModel?
    private var store: NotificationStore?
    private var fileWatcher: NotificationFileWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Log startup
        jlog("notify.start", data: ["ver": GridNotifyVersion])

        // 2. Set activation policy to .regular (visible app)
        NSApp.setActivationPolicy(.regular)

        // 3. Load config
        let config = loadNotifyConfig()
        jlog("notify.cfg.loaded", data: [
            "pipe_path": config.pipePath,
            "max_count": config.maxCount
        ])

        // 4. Load theme
        let theme: NotificationPanelTheme
        if config.themeColors.isEmpty {
            theme = .default
        } else {
            theme = NotificationPanelTheme(from: config.themeColors)
        }

        // 5. Create and load store
        let store = NotificationStore()
        self.store = store
        Task {
            await store.load()
            jlog("notify.store.ready")

            // Enforce max count
            if config.maxCount > 0 {
                await store.trim(to: config.maxCount)
            }
        }

        // 6. Create view model
        let vm = NotificationPanelViewModel(store: store, theme: theme)
        self.viewModel = vm

        // 7. Create window
        let window = NotificationPanelWindow(viewModel: vm)
        self.window = window

        // 8. Show window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // 9. Start file watcher
        if !config.pipePath.isEmpty {
            let watcherConfig = NotificationWatcherConfig(
                path: config.pipePath,
                sourceLabel: config.pipeSourceLabel
            )
            let watcher = NotificationFileWatcher(store: store, config: watcherConfig)
            watcher.onNotification = { [weak vm] in
                vm?.refreshNotifications()
            }
            watcher.start()
            self.fileWatcher = watcher
        }

        // 10. Set up signal handling for graceful shutdown
        setupSignalHandlers()

        jlog("notify.ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        fileWatcher?.stop()
        // Flush store synchronously -- applicationWillTerminate runs on main thread
        // Use a semaphore to wait for the actor method since we can't await here
        let store = self.store
        let sem = DispatchSemaphore(value: 0)
        Task {
            await store?.flush()
            sem.signal()
        }
        sem.wait()
        jlog("notify.shutdown")
    }

    private func setupSignalHandlers() {
        let signalQueue = DispatchQueue(label: "com.thegrid.notify.signals")

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigintSource.setEventHandler {
            jlog("notify.sig.int")
            self.fileWatcher?.stop()
            let store = self.store
            Task {
                await store?.flush()
                jlog("notify.shutdown.done")
                Darwin.exit(0)
            }
        }
        sigintSource.resume()
        signal(SIGINT, SIG_IGN)

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigtermSource.setEventHandler {
            jlog("notify.sig.term")
            self.fileWatcher?.stop()
            let store = self.store
            Task {
                await store?.flush()
                jlog("notify.shutdown.done")
                Darwin.exit(0)
            }
        }
        sigtermSource.resume()
        signal(SIGTERM, SIG_IGN)
    }
}
```

---

## 17. Tests [DW-1.5]

### Tests/GridNotifyTests/NotificationStoreTests.swift

3-5 tests for NotificationStore CRUD and persistence:

```
test_addAndGet:
    create store with temp file path
    add notification with known id, title, source
    get by id -> assert matches
    assert count == 1

test_dismissHidesFromActive:
    create store with temp file path
    add notification
    dismiss it
    query with .active filter -> assert count == 0
    query with .all filter -> assert count == 1

test_persistAndReload:
    create store with temp file path
    add notification
    flush store
    create new store with same path
    load
    get by id -> assert matches original
    assert count == 1

test_pinSortsFirst:
    create store with temp file path
    add n1 (not pinned)
    add n2 (not pinned)
    pin n2
    query active -> first result should be n2 (pinned)

test_filterBySearchText:
    create store with temp file path
    add notification with title "hello world"
    add notification with title "goodbye"
    query with searchText "hello" -> assert count == 1, matches first
```

---

## DW Coverage Matrix

| DW Item | Sections |
|---------|----------|
| DW-1.1 | 1 (Package.swift), 13 (Info.plist), 14 (Entitlements), 15 (Version.swift), 3 (XDG) |
| DW-1.2 | 10 (Views), 11 (Window), 13 (Info.plist), 16 (App Lifecycle) |
| DW-1.3 | 2 (Data Model), 6 (File Watcher), 7 (Source Config), 16 (App Lifecycle) |
| DW-1.4 | 2 (Data Model), 9 (ViewModel), 10 (Views), 11 (Window) |
| DW-1.5 | 2 (Data Model), 5 (Store), 16 (App Lifecycle), 17 (Tests) |
| DW-1.6 | 7 (Source Config), 8 (Theme), 12 (YAML Config), 3 (XDG) |
| DW-1.7 | 4 (Logger), 3 (XDG) |

All DW items covered. No gaps.
