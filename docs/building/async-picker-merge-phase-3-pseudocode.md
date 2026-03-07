# Pseudocode: Phase 3 - All Sources (Apps, Zoxide, Chrome Profiles, Actions)

## Files to Create/Modify

### Create
- `grid-server/Sources/GridServer/Picker/Sources/AppSource.swift`
- `grid-server/Sources/GridServer/Picker/Sources/ZoxideSource.swift`
- `grid-server/Sources/GridServer/Picker/Sources/ChromeProfileSource.swift`
- `grid-server/Sources/GridServer/Picker/Sources/ActionSource.swift`
- `grid-server/Sources/GridServer/Picker/ActionExecutor.swift`

### Modify
- `grid-server/Sources/GridServer/Picker/PickerModels.swift` — add new PickerAction cases
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` — register all sources, route to ActionExecutor
- `grid-server/Sources/GridServer/ServerConfig.swift` — add picker config with actions array

## Design: ActionExecutor

### Approaches Considered
1. **Monolithic switch in PickerManager** — All action routing stays in PickerManager.executeAction
2. **Standalone ActionExecutor struct** — Stateless struct with static methods, PickerManager delegates to it
3. **PickerAction method extension** — Each PickerAction case knows how to execute itself

### Comparison
| Criterion | A (Monolithic) | B (Standalone) | C (Self-executing) |
|-----------|---|---|---|
| Interface simplicity | Single method | Single entry point | Distributed |
| Information hiding | Mixes UI + subprocess | Hides subprocess details | Mixes concerns in enum |
| Caller ease of use | Easy but grows large | Easy | Easy but harder to test |
| Separation of concerns | Poor — PickerManager does too much | Good — execution isolated | Moderate |

### Choice: B (Standalone ActionExecutor)
Rationale: ActionExecutor hides subprocess mechanics (clean env, tmux session creation, Chrome profile args). PickerManager stays focused on UI lifecycle. The executor is a deep module — simple interface (`execute(action)`) hiding substantial subprocess orchestration.

### Depth Check
- Interface methods: 1 (`execute(_ action: PickerAction)`)
- Hidden details: environment cleaning, tmux session create-or-attach, Ghostty launch, Chrome profile args, Process spawning
- Common case complexity: simple (caller passes action, executor handles everything)

## Pseudocode

### ServerConfig.swift (modify)

```
Add PickerSourceConfig struct to ServerConfig:

struct PickerSourceConfig:
    // Custom actions defined by user
    actions: [ActionDef]
    // Optional override for zoxide binary path
    zoxidePath: String? = nil

struct ActionDef:
    name: String
    command: String
    category: String? = nil
    icon: String? = nil

Add to ServerConfig:
    picker: PickerSourceConfig = PickerSourceConfig()

Update builtinDefaults to include picker with empty actions array

Update CodingKeys to include "picker"
```

### PickerModels.swift (modify — PickerAction)

```
Extend PickerAction enum with new cases:
    case focusWindow(pid, windowID)          // existing
    case openApp(bundleID)                   // existing
    case openChromeProfile(profileDir)       // NEW
    case exec(command)                       // NEW
    case openDir(dirPath)                    // NEW

Update from(metadata:) parser:
    "focusWindow" -> existing logic
    "openApp" -> existing logic
    "openChromeProfile" -> read metadata["profileDir"], return .openChromeProfile
    "exec" -> read metadata["command"], return .exec
    "openDir" -> read metadata["dirPath"], return .openDir
```

### AppSource.swift

```
struct AppSource conforming to PickerSource:
    id = "apps"

    discover():
        // Determine directories to scan
        let dirs = ["/Applications", "/System/Applications", home + "/Applications"]

        // Track seen bundle IDs to dedup
        let seen = Set<String>

        for each dir in dirs:
            // Read directory entries, skip if directory missing
            for each entry that ends with ".app":
                // Read Info.plist from appPath/Contents/Info.plist
                let plistPath = appPath + "/Contents/Info.plist"

                // Decode plist using PropertyListSerialization
                // Extract: CFBundleIdentifier, CFBundleName, CFBundleDisplayName

                // Skip if no bundle ID or already seen
                if bundleID is empty or seen contains bundleID: skip
                seen.insert(bundleID)

                // Determine display name: DisplayName -> BundleName -> filename without .app
                let name = displayName ?? bundleName ?? basename(appPath, ".app")

                // Build PickerItem
                PickerItem(
                    id: "app:" + bundleID,
                    title: name,
                    subtitle: bundleID,
                    icon: "bundle:" + bundleID,
                    searchable: [name.lowercased(), bundleID.lowercased()],
                    metadata: [
                        "action": "openApp",
                        "bundleID": bundleID,
                        "appPath": appPath
                    ],
                    priority: 100
                )

        return items sorted by title
```

### ZoxideSource.swift

```
struct ZoxideSource conforming to PickerSource:
    id = "zoxide"
    let configuredPath: String?   // optional override from config

    discover():
        // Find zoxide binary
        let zoxidePath = findZoxide(configuredPath)
        if zoxidePath is nil: return empty (zoxide not installed, not an error)

        // Run: zoxide query -l
        let output = await runProcess(zoxidePath, args: ["query", "-l"])
        if output is nil: return empty

        let home = NSHomeDirectory()
        var items: [PickerItem] = []

        for each non-empty line in output split by newline:
            let dir = line.trimmed

            // Display path with ~ substitution
            let displayPath = if dir starts with home: "~" + rest, else: dir

            // Title is basename
            let title = lastPathComponent(dir)

            PickerItem(
                id: "zoxide:" + displayPath,
                title: title,
                subtitle: displayPath,
                icon: "folder",
                searchable: [title.lowercased(), displayPath.lowercased()],
                metadata: [
                    "action": "openDir",
                    "dirPath": dir
                ],
                priority: 50
            )

        return items

    private findZoxide(configuredPath):
        // 1. Config override (use unconditionally if set)
        if configuredPath is non-nil and non-empty:
            if file exists: return it
            else: log warning, return nil

        // 2. Check known paths (server has minimal PATH)
        let candidates = [
            home + "/.cargo/bin/zoxide",
            "/opt/homebrew/bin/zoxide",
            "/usr/local/bin/zoxide"
        ]
        for each candidate:
            if isExecutableFile: return candidate

        return nil
```

### ChromeProfileSource.swift

```
struct ChromeProfileSource conforming to PickerSource:
    id = "chrome"

    discover():
        // Read Chrome Local State
        let localStatePath = home + "/Library/Application Support/Google/Chrome/Local State"

        // Read file, parse JSON
        let data = try read file at localStatePath
        if file missing: return empty (Chrome not installed)

        // Parse JSON structure: { "profile": { "info_cache": { "Profile 1": {...}, ... } } }
        let json = JSONSerialization or Codable decode
        let infoCache = json["profile"]["info_cache"] as dict
        if infoCache is nil: return empty

        var items: [PickerItem] = []

        for each (profileDir, profileInfo) in infoCache:
            // Determine best display name
            // Priority: name (if not default) -> gaiaName -> shortcutName -> userName -> profileDir
            let name: String
            if profileInfo.name is non-empty and not isUsingDefaultName:
                name = profileInfo.name
            else if gaiaName non-empty: name = gaiaName
            else if shortcutName non-empty: name = shortcutName
            else if userName non-empty: name = userName
            else: name = profileDir

            // Build searchable: name, "chrome", "browser", gaia/user names
            let searchable = [name.lowercased(), "chrome", "browser"]
            // Add gaiaName and userName if different from primary name

            PickerItem(
                id: "chrome:" + profileDir,
                title: name,
                subtitle: "Chrome Profile",
                icon: "bundle:com.google.Chrome",
                searchable: searchable,
                metadata: [
                    "action": "openChromeProfile",
                    "profileDir": profileDir
                ],
                priority: 100
            )

        return items
```

### ActionSource.swift

```
struct ActionSource conforming to PickerSource:
    id = "actions"
    let actions: [ActionDef]   // from ServerConfig.picker.actions

    discover():
        // Pure transformation — no async work needed
        var items: [PickerItem] = []

        for each actionDef in actions:
            if name is empty or command is empty: skip

            // Generate stable ID: "action:" + slugified name
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            let id = "action:" + slug

            // Icon: from config, or default "terminal"
            let icon = actionDef.icon ?? "terminal"

            // Subtitle: category or "Action"
            let subtitle = actionDef.category ?? "Action"

            // Searchable: name words + category
            var searchable = [name.lowercased()]
            if category is non-empty: searchable.append(category.lowercased())
            // Add individual words from name
            for each word in name split by spaces:
                if word.lowercased() != searchable[0]:
                    searchable.append(word.lowercased())

            PickerItem(
                id: id,
                title: name,
                subtitle: subtitle,
                icon: icon,
                searchable: searchable,
                metadata: [
                    "action": "exec",
                    "command": actionDef.command
                ],
                priority: 150
            )

        return items
```

### ActionExecutor.swift

```
struct ActionExecutor:
    // Stateless — all methods are static

    static func execute(_ action: PickerAction):
        switch action:
        case .focusWindow(pid, windowID):
            // Use WindowManipulator (existing pattern from PickerManager)
            let connectionID = SLSMainConnectionID()
            let manipulator = WindowManipulator(connectionID: connectionID)
            manipulator.focusWindow(pid: pid, windowID: windowID)
            log result

        case .openApp(bundleID):
            // Use NSWorkspace to open by bundle ID
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID):
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                    if error: log error
                }

        case .openChromeProfile(profileDir):
            // Spawn: open -na "Google Chrome" --args --profile-directory="Profile 1"
            // Use runProcessFireAndForget with clean environment
            spawnDetached("/usr/bin/open", args: [
                "-na", "Google Chrome", "--args",
                "--profile-directory=" + profileDir
            ], cleanEnv: true)

        case .exec(command):
            // Run command via shell with clean environment
            let shell = userShell()
            spawnDetached(shell, args: ["-c", command], cleanEnv: true)

        case .openDir(dirPath):
            // Create or attach tmux session, open in Ghostty
            // Must run async because tmux commands need to be awaited
            Task {
                await openDirInTmux(dirPath)
            }

    private static func openDirInTmux(_ dirPath: String):
        let sessionName = sanitizeTmuxName(basename(dirPath))
        let tmuxPath = findTmux()

        // Boost zoxide frecency (best-effort, fire-and-forget)
        if let zoxide = findZoxideBinary():
            _ = await runProcess(zoxide, args: ["add", dirPath])

        // Check if session exists (await — need exit status)
        let hasSession = await runProcess(tmuxPath, args: ["has-session", "-t", sessionName])

        if hasSession is nil (session doesn't exist):
            // Create new detached session (await — must complete before attach)
            _ = await runProcess(tmuxPath, args: [
                "new-session", "-d", "-s", sessionName, "-c", dirPath
            ])

        // Open Ghostty with tmux attach (fire-and-forget)
        let shell = userShell()
        let attachCmd = tmuxPath + " attach -t " + sessionName
        spawnDetached("/usr/bin/open", args: [
            "-na", "Ghostty", "--args",
            "--title=" + sessionName,
            "--command=" + shell + " -l -c '" + attachCmd + "'"
        ], cleanEnv: true)

    // Helper: get user's default shell
    private static func userShell() -> String:
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    // Helper: clean environment (strip TMUX vars)
    private static func cleanEnvironment() -> [String: String]:
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        env.removeValue(forKey: "TMUX_PLUGIN_MANAGER_PATH")
        return env

    // Helper: sanitize tmux session name (no dots or colons)
    private static func sanitizeTmuxName(_ name: String) -> String:
        return name
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")

    // Helper: find zoxide binary (same pattern as findTmux)
    private static func findZoxideBinary() -> String?:
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.cargo/bin/zoxide",
            "/opt/homebrew/bin/zoxide",
            "/usr/local/bin/zoxide"
        ]
        for path in candidates:
            if FileManager.default.isExecutableFile(atPath: path):
                return path
        return nil

    // Helper: spawn process detached, don't wait for result
    // Runs on DispatchQueue.global() to avoid blocking main thread
    private static func spawnDetached(_ exe: String, args: [String], cleanEnv: Bool = false):
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            if cleanEnv:
                process.environment = cleanEnvironment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do:
                try process.run()
                // Don't waitUntilExit — fire and forget
            catch:
                jlog("pick.exec.err", data: ["exe": exe, "err": error.localizedDescription])
        }
```

### PickerManager.swift (modify)

```
Changes to PickerManager:

1. Add stored config property:
    private var config: ServerConfig?

    // Add configure method called after server startup
    func configure(with config: ServerConfig):
        self.config = config

2. In discoverAndStream(), replace source array:
    let enricher = WindowEnricher()
    var sources: [PickerSource] = [
        WindowSource(enricher: enricher),
        AppSource(),
        ChromeProfileSource(),
    ]

    // Add zoxide source (needs config for optional path override)
    sources.append(ZoxideSource(configuredPath: config?.picker.zoxidePath))

    // Add action source if config has actions defined
    if let actions = config?.picker.actions, !actions.isEmpty:
        sources.append(ActionSource(actions: actions))

    // Rest of TaskGroup logic is UNCHANGED

3. In executeAction(for:), replace inline switch:
    private func executeAction(for item: PickerItem):
        guard let action = PickerAction.from(metadata: item.metadata) else:
            jlog("pick.err.noaction", data: ["id": item.id])
            return
        ActionExecutor.execute(action)
```

## Design Notes

### Info.plist Parsing
Swift has native plist support via `PropertyListSerialization.propertyList(from:)`. Use dictionary access (`NSDictionary`) rather than Codable for flexibility — plist keys vary across apps. Access `CFBundleIdentifier`, `CFBundleName`, `CFBundleDisplayName` as optional strings.

### Chrome Local State Parsing
Use Codable structs matching the Go `chromeLocalState` shape. The structure is: `{ "profile": { "info_cache": { "<dir>": { "name": "...", "gaia_name": "...", ... } } } }`.

### Zoxide Binary Discovery
Cannot rely on `PATH` in daemon context — server launches via launchd with minimal environment. Must check absolute paths. Same pattern as `findTmux()` in EnrichmentTypes.swift.

### Fire-and-Forget vs Awaited Subprocesses
- `open -na` commands are fire-and-forget (GUI app launch, returns immediately)
- `tmux has-session` must be awaited (need exit status)
- `tmux new-session -d` must be awaited (need it to complete before attach)
- `zoxide add` is best-effort (fire-and-forget)

### Config Loading
ServerConfig currently loads async via `ServerConfig.load()`. PickerManager needs access to actions config. Pass config via `configure(with:)` after server startup. Store reference for use during `discoverAndStream()`.

### Source Priority Values
Per plan: Windows=1000, Apps=100, Chrome=100, Actions=150, Zoxide=50. Set on each PickerItem, used by frecency sort as tiebreaker.

### Spinner
Already implemented in Phase 1. `PickerWindow.setLoading(true)` on show, `setLoading(false)` when all sources complete. No additional work needed.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (ActionExecutor deep module design)
- [x] Ready for implementation
