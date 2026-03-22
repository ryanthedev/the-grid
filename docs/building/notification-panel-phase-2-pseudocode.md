# Pseudocode: Phase 2 - NSWindow, SwiftUI views, and vim keybindings

## Design-It-Twice: Key Architectural Decisions

### Decision 1: View Model Bridging (NotificationStore actor -> SwiftUI)

#### Approaches Considered
1. **Direct actor calls from SwiftUI** -- SwiftUI views call `await store.notifications()` in `.task` modifiers, storing results in `@State` arrays.
2. **ObservableObject view model** -- A `@MainActor` class with `@Published` properties that subscribes to store changes and updates SwiftUI reactively.
3. **Combine publisher on the actor** -- The actor exposes a `PassthroughSubject` that publishes change events; SwiftUI views subscribe.

#### Comparison
| Criterion | A: Direct actor calls | B: ObservableObject VM | C: Combine publisher |
|-----------|----------------------|----------------------|---------------------|
| Interface simplicity | Simple but scattered | One ViewModel, clean | Medium complexity |
| Information hiding | Low (views know actor API) | High (views know only VM) | Medium |
| Caller ease of use | Needs .task + manual refresh | Automatic via @Published | Needs .onReceive |
| Testability | Hard (needs actor mock) | Easy (VM is injectable) | Medium |
| Keyboard state management | Must live elsewhere | Natural home for mode/selection | Must live elsewhere |

#### Choice: B (ObservableObject view model)
Rationale: The view model is the natural place to hold UI state (selected index, mode, filter text, visual selection range) AND bridge the notification data from the actor. SwiftUI views become purely declarative renderers. The VM also provides a clean place for the NSWindow to dispatch vim key actions into.

#### Depth Check
- Interface methods: ~8 (refreshNotifications, selectNext, selectPrevious, dismiss, togglePin, changePriority, executeAction, setFilterText)
- Hidden details: Actor interaction, filter application, scroll management, mode transitions
- Common case complexity: Simple -- views bind to @Published properties

---

### Decision 2: Keyboard Mode State Machine

#### Approaches Considered
1. **Flat if/else in keyDown** -- Single keyDown method with a big switch, mode tracked by a boolean.
2. **Enum-based state machine** -- Explicit `PanelMode` enum (normal, filter, visualSelect) with per-mode key dispatch tables.
3. **Separate NSView per mode** -- Different first responders for different modes (text field for filter, custom view for normal).

#### Comparison
| Criterion | A: Flat switch | B: Enum state machine | C: Separate views |
|-----------|---------------|----------------------|-------------------|
| Interface simplicity | Simple initially | Slightly more structure | Most complex |
| Extensibility | Degrades with modes | Clean per-mode dispatch | Over-engineered |
| Information hiding | Low (all in one place) | High (mode logic encapsulated) | High but fragmented |
| Matches PickerWindow pattern | Yes (it uses flat) | Extension of flat approach | No |

#### Choice: B (Enum state machine)
Rationale: The notification panel has 3 distinct modes with different key mappings. A flat switch with 15+ key bindings across 3 modes becomes unreadable. The enum state machine keeps each mode's bindings isolated. The state machine lives in the view model, and the window's keyDown simply delegates to it.

#### Depth Check
- Interface: `handleKey(keyCode, modifiers) -> KeyAction` on the view model
- Hidden: Mode transitions, per-mode key tables, modifier handling
- Common case: Normal mode j/k navigation -- one method call

---

### Decision 3: Theme/Color System

#### Approaches Considered
1. **Static constants** -- A `NotificationColors` struct like PickerColors with hardcoded values.
2. **Configurable struct** -- A `NotificationPanelTheme` struct passed to the view model at init, with sensible defaults.
3. **Environment-injected theme** -- SwiftUI `@Environment` with custom EnvironmentKey for theme propagation.

#### Comparison
| Criterion | A: Static constants | B: Configurable struct | C: Environment injection |
|-----------|-------------------|----------------------|------------------------|
| Interface simplicity | Simplest | Simple with init param | SwiftUI-idiomatic |
| Supports Phase 5 config | No (hardcoded) | Yes (replace at init) | Yes |
| Hot-reload support | No | Replace struct + refresh | Replace + environment update |
| Matches codebase patterns | Yes (PickerColors) | Extension of it | New pattern |

#### Choice: B (Configurable struct)
Rationale: Phase 5 needs to replace colors from YAML config. A struct passed at init time is the simplest path that supports future configurability. For Phase 2, we provide a `static let default` with the dark theme. The struct is also passed into SwiftUI views so they reference theme colors, not global constants.

### Color Palette Design

Following the color theory decision tree:

**Mood:** Mysterious/Exclusive (dark background + sparse bright accents) -- this matches the existing Ghostty-inspired dark theme used by the picker.

**Background:** Dark (content-dense notification list needs contrast, but the "exclusive" terminal-user aesthetic calls for dark mode).

**Color scheme type:** Monochromatic with one accent -- quiet, focused, functional. The notification panel is a utility, not a creative canvas.

**Base hue:** The existing border system uses red (#FF0000) as the active accent and #666666 as inactive. The picker uses #00BFFF (cyan/bright blue) as its accent. The notification panel should use a distinct accent that doesn't clash with borders (red) or picker (blue).

**Chosen accent: The existing border active color (configurable, defaults to red).** The notification panel should mirror whatever the user's active border color is, creating visual cohesion. This means the accent color comes from `BorderConfigManager.shared.activeStyle.color`. But for Phase 2 (stub config), we'll default to a warm orange-amber (#FF9500) as a distinct notification-specific accent that:
- Reads as "attention/notification" (warm = pops forward)
- Doesn't conflict with red borders (error connotation) or blue picker accent (links connotation)
- Is warm enough to create depth against the cool dark background
- Follows the functional color convention: yellow/orange = highlights/attention

**Palette derivation (monochromatic-plus-accent):**

| Token | Hex | Role | Rationale |
|-------|-----|------|-----------|
| background | #121212 | Window background | Matches PickerColors.background for consistency |
| surface | #1E1E1E | Card/item background | Slightly lifted for depth, not as light as input (#232323) |
| surfaceSelected | #2A2A2A | Selected item highlight | Warm-shifted dark to create pop |
| textPrimary | #BFBFBF | Main text (title) | Matches PickerColors.text |
| textSecondary | #808080 | Body/metadata text | Slightly dimmer, distinct from primary |
| textTertiary | #5A5A5A | Timestamps, source labels | Recedes further |
| accent | #FF9500 | Priority indicators, action hints, pin markers | Warm attention color |
| accentDim | #CC7700 | Unfocused accent elements | Shaded accent |
| urgent | #FF3B30 | Urgent priority indicator | Red = urgency (convention) |
| pinned | #FFD60A | Pin indicator | Yellow = highlight/attention (convention) |
| border | #333333 | Subtle dividers | Low contrast for quiet separation |
| filterBackground | #232323 | Filter input background | Matches PickerColors.inputBackground |

**Redundant cues for priority:** Priority is conveyed by BOTH color AND a text prefix icon (symbols that work without color):
- urgent: red + "!" prefix
- high: accent + "^" prefix
- normal: no color marker
- low: tertiary text + "." prefix

**Colorblindness:** The warm orange accent vs. cool gray background has excellent contrast for all colorblindness types (deuteranopia, protanopia). Pin (yellow) vs. urgent (red) could be confusable for protanopia, but we use different symbols (pin icon vs. "!" marker) as redundant cues.

**Shadows:** Any depth effects use a cool-shifted dark (#0A0A14, slightly blue-black) rather than pure black, following the hue-shifted shadow principle.

---

## Files to Create/Modify

### New Files
1. `grid-server/Sources/GridServer/Notifications/NotificationPanelTheme.swift` -- Theme color struct
2. `grid-server/Sources/GridServer/Notifications/NotificationPanelViewModel.swift` -- ObservableObject bridging store to SwiftUI
3. `grid-server/Sources/GridServer/Notifications/NotificationPanelWindow.swift` -- NSWindow subclass with keyDown
4. `grid-server/Sources/GridServer/Notifications/NotificationPanelViews.swift` -- SwiftUI views
5. `grid-server/Sources/GridServer/Notifications/NotificationPanelManager.swift` -- Singleton lifecycle orchestrator

### No Modifications to Existing Files
Phase 2 is standalone -- no wiring into main.swift, GridCommandRouter, or EventRouter. That happens in Phase 3.

---

## Pseudocode

### NotificationPanelTheme.swift

```
import SwiftUI (for Color type)

struct NotificationPanelTheme
  -- All colors as SwiftUI Color for direct use in views
  -- Also stores NSColor equivalents for the window background

  properties:
    background: Color          -- #121212
    surface: Color             -- #1E1E1E
    surfaceSelected: Color     -- #2A2A2A
    textPrimary: Color         -- #BFBFBF
    textSecondary: Color       -- #808080
    textTertiary: Color        -- #5A5A5A
    accent: Color              -- #FF9500
    accentDim: Color           -- #CC7700
    urgent: Color              -- #FF3B30
    pinned: Color              -- #FFD60A
    border: Color              -- #333333
    filterBackground: Color    -- #232323

    -- NSColor version of background for NSWindow.backgroundColor
    windowBackgroundNSColor: NSColor

  static let `default` = NotificationPanelTheme(
    -- populate with the hex values above
  )

  -- Convenience init from hex strings (used by Phase 5 YAML config)
  init(from dictionary: [String: String])
    -- parse each key as hex, fall back to defaults for missing keys
```

### NotificationPanelViewModel.swift

```
import SwiftUI
import Combine

-- Keyboard interaction mode
enum NotificationPanelMode
  case normal        -- vim navigation (j/k/d/x/Enter/p/+/-/V)
  case filter        -- typing filter text (/ activated, Esc returns to normal)
  case visualSelect  -- multi-select for bulk ops (V activated, Esc returns to normal)

-- Actions the view model can tell the window to perform
enum NotificationPanelAction
  case none
  case executeAction(GridNotificationAction)  -- run the notification's action
  case enterFilterMode                        -- make filter text field first responder
  case exitFilterMode                         -- return first responder to window

@MainActor
class NotificationPanelViewModel: ObservableObject

  -- Published properties for SwiftUI binding
  @Published var notifications: [GridNotification] = []
  @Published var selectedIndex: Int = 0
  @Published var mode: NotificationPanelMode = .normal
  @Published var filterText: String = ""
  @Published var visualSelectionStart: Int? = nil  -- set when V is pressed
  @Published var statusText: String = ""           -- bottom status bar text

  -- Theme (passed at init, can be replaced for hot-reload)
  var theme: NotificationPanelTheme

  -- Reference to the store (actor, called with await)
  private let store: NotificationStore

  -- Scroll state
  private let maxVisibleHeight: CGFloat = 600
  var scrollOffset: Int = 0

  init(store: NotificationStore, theme: NotificationPanelTheme = .default)
    self.store = store
    self.theme = theme

  -- MARK: - Data Loading

  func refreshNotifications()
    -- Build filter from current filterText
    -- Call store.notifications(filter:) on the actor
    -- Update self.notifications on @MainActor
    -- Clamp selectedIndex to valid range
    -- Update statusText with count summary
    Task {
      let filter = buildFilter()
      let results = await store.notifications(filter: filter)
      self.notifications = results
      self.selectedIndex = min(self.selectedIndex, max(0, results.count - 1))
      self.updateStatusText()
    }

  private func buildFilter() -> GridNotificationFilter
    var filter = GridNotificationFilter.active
    if !filterText.isEmpty
      filter.searchText = filterText
    return filter

  private func updateStatusText()
    -- Format: "3 notifications | 1 pinned | filter: <text>"
    -- Or: "VISUAL: 2 selected | d to dismiss, p to pin"
    -- Based on current mode

  -- MARK: - Navigation

  func selectNext()
    guard !notifications.isEmpty
    selectedIndex = min(selectedIndex + 1, notifications.count - 1)
    ensureVisible(selectedIndex)

  func selectPrevious()
    guard !notifications.isEmpty
    selectedIndex = max(selectedIndex - 1, 0)
    ensureVisible(selectedIndex)

  func selectFirst()
    selectedIndex = 0
    scrollOffset = 0

  func selectLast()
    guard !notifications.isEmpty
    selectedIndex = notifications.count - 1
    ensureVisible(selectedIndex)

  private func ensureVisible(_ index: Int)
    -- Adjust scrollOffset so index is in the visible window
    -- Mirrors PickerState scroll logic but simpler (fixed item heights)

  -- MARK: - Actions

  func dismissSelected() -> Bool
    guard let notification = currentNotification
    Task { await store.dismiss(id: notification.id); refreshNotifications() }
    return true

  func togglePinSelected() -> Bool
    guard let notification = currentNotification
    if notification.isPinned
      Task { await store.unpin(id: notification.id); refreshNotifications() }
    else
      Task { await store.pin(id: notification.id); refreshNotifications() }
    return true

  func increasePriority() -> Bool
    guard let notification = currentNotification
    let nextPriority = priorityAbove(notification.priority)
    if nextPriority != notification.priority
      Task { await store.setPriority(id: notification.id, priority: nextPriority); refreshNotifications() }
    return true

  func decreasePriority() -> Bool
    -- same pattern, priorityBelow

  func executeSelectedAction() -> NotificationPanelAction
    guard let notification = currentNotification
    -- Mark as read
    Task { await store.markRead(id: notification.id) }
    if let action = notification.action
      return .executeAction(action)
    return .none

  var currentNotification: GridNotification?
    guard selectedIndex >= 0, selectedIndex < notifications.count
    return notifications[selectedIndex]

  -- MARK: - Visual Select Mode

  func enterVisualSelect()
    mode = .visualSelect
    visualSelectionStart = selectedIndex
    updateStatusText()

  func exitVisualSelect()
    mode = .normal
    visualSelectionStart = nil
    updateStatusText()

  var visualSelectedRange: ClosedRange<Int>?
    guard let start = visualSelectionStart
    let end = selectedIndex
    return min(start, end)...max(start, end)

  func bulkDismissVisualSelection()
    guard let range = visualSelectedRange
    let idsToDismmiss = notifications[range].map { $0.id }
    Task {
      for id in idsToDismmiss
        await store.dismiss(id: id)
      refreshNotifications()
    }
    exitVisualSelect()

  func bulkPinVisualSelection()
    -- same pattern for pin

  -- MARK: - Filter Mode

  func enterFilterMode()
    mode = .filter
    updateStatusText()

  func exitFilterMode()
    mode = .normal
    updateStatusText()

  func updateFilter(_ text: String)
    filterText = text
    refreshNotifications()

  func clearFilter()
    filterText = ""
    refreshNotifications()

  -- MARK: - Key Handling

  -- Called by the NSWindow's keyDown. Returns an action for the window to execute.
  func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NotificationPanelAction

    switch mode

    case .normal:
      switch keyCode
        case 38 (j): selectNext(); return .none
        case 40 (k): selectPrevious(); return .none
        case 2 (d): dismissSelected(); return .none
        case 7 (x): dismissSelected(); return .none
        case 36 (Return): return executeSelectedAction()
        case 44 (/): enterFilterMode(); return .enterFilterMode
        case 35 (p): togglePinSelected(); return .none
        case 24 (+ with shift): increasePriority(); return .none
        case 27 (- without shift): decreasePriority(); return .none
        case 9 (V with shift): enterVisualSelect(); return .none
        case 5 (g): if shifted: selectLast() else: selectFirst(); return .none
        case 53 (Escape): return .none  -- no-op in normal mode (or could hide panel)
        default: return .none

    case .filter:
      -- Filter mode keys are handled by the text field delegate
      -- Only Escape reaches the window (to exit filter mode)
      switch keyCode
        case 53 (Escape): exitFilterMode(); return .exitFilterMode
        default: return .none  -- text field handles everything else

    case .visualSelect:
      switch keyCode
        case 38 (j): selectNext(); return .none
        case 40 (k): selectPrevious(); return .none
        case 2 (d): bulkDismissVisualSelection(); return .none
        case 35 (p): bulkPinVisualSelection(); return .none
        case 53 (Escape): exitVisualSelect(); return .none
        default: return .none

  -- Helper to map priority up/down
  private func priorityAbove(_ p: GridNotificationPriority) -> GridNotificationPriority
    switch p
      case .low: return .normal
      case .normal: return .high
      case .high: return .urgent
      case .urgent: return .urgent

  private func priorityBelow(_ p: GridNotificationPriority) -> GridNotificationPriority
    switch p
      case .urgent: return .high
      case .high: return .normal
      case .normal: return .low
      case .low: return .low
```

### NotificationPanelWindow.swift

```
import AppKit
import SwiftUI

class NotificationPanelWindow: NSWindow

  -- The view model (owned here, shared with SwiftUI views)
  private let viewModel: NotificationPanelViewModel

  -- The hosting view wrapping SwiftUI content
  private var hostingView: NSHostingView<NotificationPanelContentView>?

  -- Filter text field (shown only during filter mode)
  -- Lives in the AppKit layer so we can control first responder
  private var filterTextField: NSTextField?

  init(viewModel: NotificationPanelViewModel)
    self.viewModel = viewModel

    -- Calculate initial window rect
    let screen = NSScreen.main ?? NSScreen.screens.first!
    let width: CGFloat = 400
    let height: CGFloat = 600
    let origin = NSPoint(
      x: screen.frame.midX - width / 2,
      y: screen.frame.midY - height / 2
    )

    super.init(
      contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
      -- Use titled + closable so it appears as a real window in CGWindowListCopyWindowInfo
      -- Use fullSizeContentView to control rendering
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    setupWindow()
    setupContent()

  private func setupWindow()
    -- Standard window (NOT floating, NOT transient)
    -- Must appear in CGWindowListCopyWindowInfo
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isOpaque = false
    backgroundColor = viewModel.theme.windowBackgroundNSColor
    hasShadow = true
    -- Set the window title for identification (used by Phase 3 blacklisting)
    title = "Grid Notifications"
    -- Allow the window to become key so it receives keyboard input
    -- isReleasedWhenClosed = false so we can reuse across show/hide

  private func setupContent()
    -- Create the SwiftUI content view
    let swiftUIView = NotificationPanelContentView(viewModel: viewModel)
    let hosting = NSHostingView(rootView: swiftUIView)
    hosting.translatesAutoresizingMaskIntoConstraints = false

    -- Set as content view
    contentView = hosting
    hostingView = hosting

  -- MARK: - Key Handling

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func keyDown(with event: NSEvent)
    let action = viewModel.handleKeyDown(
      keyCode: event.keyCode,
      modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    )

    switch action
    case .none:
      break  -- key was consumed by viewModel
    case .executeAction(let notifAction):
      -- Delegate to manager/caller for action execution
      -- (Phase 2: just log it; Phase 3: wire to ActionExecutor)
      jlog("notify.action", data: ["action": "\(notifAction)"])
    case .enterFilterMode:
      -- Make the filter text field first responder
      -- The SwiftUI view shows the filter bar; we just need to focus it
      -- Since SwiftUI manages the text field, we use a FocusState binding
      break
    case .exitFilterMode:
      -- Return first responder to the window itself
      makeFirstResponder(nil)

  -- MARK: - Window overrides for responder chain

  -- In filter mode, if a text field is first responder, keyDown won't reach here.
  -- The text field's delegate handles Enter (apply filter) and Escape (exit filter).
  -- Other keys go to normal text editing.
```

### NotificationPanelViews.swift

```
import SwiftUI

-- MARK: - Main Content View

struct NotificationPanelContentView: View
  @ObservedObject var viewModel: NotificationPanelViewModel

  var body: some View
    VStack(spacing: 0)
      -- Header bar
      NotificationHeaderView(viewModel: viewModel)

      -- Filter bar (visible only in filter mode)
      if viewModel.mode == .filter
        NotificationFilterBar(viewModel: viewModel)

      -- Notification list (scrollable)
      if viewModel.notifications.isEmpty
        NotificationEmptyView(theme: viewModel.theme)
      else
        NotificationListView(viewModel: viewModel)

      -- Status bar
      NotificationStatusBar(viewModel: viewModel)

    .background(viewModel.theme.background)
    .onAppear
      viewModel.refreshNotifications()

-- MARK: - Header View

struct NotificationHeaderView: View
  @ObservedObject var viewModel: NotificationPanelViewModel

  var body: some View
    HStack
      Text("Notifications")
        .font(.custom("BerkeleyMono Nerd Font", size: 15).bold()
              ?? .system(size: 15, weight: .bold, design: .monospaced))
        .foregroundColor(viewModel.theme.textPrimary)

      Spacer()

      -- Unread count badge
      if unreadCount > 0
        Text("\(unreadCount)")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(viewModel.theme.background)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(viewModel.theme.accent)
          .clipShape(Capsule())
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(viewModel.theme.surface)

  private var unreadCount: Int
    viewModel.notifications.filter { !$0.isRead }.count

-- MARK: - Filter Bar

struct NotificationFilterBar: View
  @ObservedObject var viewModel: NotificationPanelViewModel
  @FocusState private var isFilterFocused: Bool

  var body: some View
    HStack(spacing: 8)
      Text("/")
        .font(.system(size: 14, design: .monospaced))
        .foregroundColor(viewModel.theme.accent)

      TextField("filter...", text: filterTextBinding)
        .textFieldStyle(.plain)
        .font(.system(size: 14, design: .monospaced))
        .foregroundColor(viewModel.theme.textPrimary)
        .focused($isFilterFocused)
        .onSubmit
          -- Enter pressed: exit filter mode, keep filter applied
          viewModel.exitFilterMode()
        .onExitCommand
          -- Escape pressed: exit filter mode, clear filter
          viewModel.clearFilter()
          viewModel.exitFilterMode()

    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(viewModel.theme.filterBackground)
    .onAppear
      isFilterFocused = true

  private var filterTextBinding: Binding<String>
    Binding(
      get: { viewModel.filterText },
      set: { viewModel.updateFilter($0) }
    )

-- MARK: - Notification List

struct NotificationListView: View
  @ObservedObject var viewModel: NotificationPanelViewModel

  var body: some View
    ScrollViewReader { proxy in
      ScrollView
        LazyVStack(spacing: 2)
          ForEach(Array(viewModel.notifications.enumerated()), id: \.element.id) { index, notification in
            NotificationItemView(
              notification: notification,
              isSelected: index == viewModel.selectedIndex,
              isVisualSelected: viewModel.visualSelectedRange?.contains(index) ?? false,
              theme: viewModel.theme
            )
            .id(notification.id)
          }
      .onChange(of: viewModel.selectedIndex) { newIndex in
        -- Scroll to keep selected item visible
        if let notification = viewModel.currentNotification
          withAnimation(.easeInOut(duration: 0.1))
            proxy.scrollTo(notification.id, anchor: .center)

-- MARK: - Single Notification Item

struct NotificationItemView: View
  let notification: GridNotification
  let isSelected: Bool
  let isVisualSelected: Bool
  let theme: NotificationPanelTheme

  var body: some View
    HStack(alignment: .top, spacing: 10)
      -- Priority indicator (left edge)
      priorityIndicator

      -- Content
      VStack(alignment: .leading, spacing: 3)
        -- Title row
        HStack
          -- Pin indicator
          if notification.isPinned
            Text(pinSymbol)
              .font(.system(size: 12))
              .foregroundColor(theme.pinned)

          Text(notification.title)
            .font(.custom("BerkeleyMono Nerd Font", size: 14)
                  ?? .system(size: 14, weight: .regular, design: .monospaced))
            .foregroundColor(notification.isRead ? theme.textSecondary : theme.textPrimary)
            .lineLimit(1)

          Spacer()

          -- Source tag
          Text(notification.source)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(theme.textTertiary)

        -- Body (if present)
        if !notification.body.isEmpty
          Text(notification.body)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(theme.textSecondary)
            .lineLimit(2)

        -- Bottom row: timestamp + action indicator
        HStack
          Text(relativeTime(notification.timestamp))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.textTertiary)

          if notification.action != nil
            Spacer()
            Text("Enter")
              .font(.system(size: 10, design: .monospaced))
              .foregroundColor(theme.accentDim)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .overlay(
                RoundedRectangle(cornerRadius: 3)
                  .stroke(theme.accentDim, lineWidth: 0.5)
              )

    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(backgroundColor)
    .cornerRadius(4)

  -- Background color based on selection state
  private var backgroundColor: Color
    if isSelected
      return theme.surfaceSelected
    if isVisualSelected
      return theme.surface.opacity(0.8)
    return Color.clear

  -- Priority indicator: colored bar on left edge + symbol
  @ViewBuilder
  private var priorityIndicator: some View
    let (color, symbol) = priorityVisuals(notification.priority)
    VStack
      Text(symbol)
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(color)
    .frame(width: 14)

  private func priorityVisuals(_ priority: GridNotificationPriority) -> (Color, String)
    switch priority
      case .urgent: return (theme.urgent, "!")
      case .high:   return (theme.accent, "^")
      case .normal: return (.clear, " ")
      case .low:    return (theme.textTertiary, ".")

  -- Pin symbol
  private var pinSymbol: String
    return "+"  -- simple text-based pin indicator

  -- Relative time formatting
  private func relativeTime(_ date: Date) -> String
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "now" }
    if interval < 3600 { return "\(Int(interval / 60))m" }
    if interval < 86400 { return "\(Int(interval / 3600))h" }
    return "\(Int(interval / 86400))d"

-- MARK: - Empty State

struct NotificationEmptyView: View
  let theme: NotificationPanelTheme

  var body: some View
    VStack(spacing: 8)
      Text("No notifications")
        .font(.system(size: 15, design: .monospaced))
        .foregroundColor(theme.textTertiary)
      Text("Notifications from CLI, events, and file watchers appear here")
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(theme.textTertiary)
        .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)

-- MARK: - Status Bar

struct NotificationStatusBar: View
  @ObservedObject var viewModel: NotificationPanelViewModel

  var body: some View
    HStack
      Text(viewModel.statusText)
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(viewModel.theme.textTertiary)
        .lineLimit(1)

      Spacer()

      -- Mode indicator
      switch viewModel.mode
      case .normal:
        Text("NORMAL")
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundColor(viewModel.theme.textTertiary)
      case .filter:
        Text("FILTER")
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundColor(viewModel.theme.accent)
      case .visualSelect:
        Text("VISUAL")
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundColor(viewModel.theme.pinned)

    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(viewModel.theme.surface)
```

### NotificationPanelManager.swift

```
import AppKit

-- Singleton orchestrator for notification panel lifecycle.
-- Follows PickerManager pattern: main-thread class, not actor.
-- All methods must be called on the main thread.

class NotificationPanelManager

  static let shared = NotificationPanelManager()

  private var window: NotificationPanelWindow?
  private var viewModel: NotificationPanelViewModel?
  private var isVisible = false

  private init()

  -- MARK: - Configuration

  -- Configure with theme (call after server startup, can be called again for hot-reload)
  func configure(theme: NotificationPanelTheme = .default)
    dispatchPrecondition(condition: .onQueue(.main))
    -- If view model exists, update its theme
    -- If not, store theme for lazy window creation
    if let vm = viewModel
      vm.theme = theme
    self.storedTheme = theme

  private var storedTheme: NotificationPanelTheme = .default

  -- MARK: - Show / Hide / Toggle

  func show()
    dispatchPrecondition(condition: .onQueue(.main))

    if isVisible
      return
    isVisible = true

    -- Create window lazily
    if window == nil
      let vm = NotificationPanelViewModel(store: NotificationStore.shared, theme: storedTheme)
      viewModel = vm
      window = NotificationPanelWindow(viewModel: vm)

    -- Refresh notifications before showing
    viewModel?.refreshNotifications()

    -- Activate and show
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    jlog("notify.panel.show")

  func hide()
    dispatchPrecondition(condition: .onQueue(.main))

    guard isVisible else { return }
    isVisible = false

    window?.orderOut(nil)
    jlog("notify.panel.hide")

  func toggle()
    dispatchPrecondition(condition: .onQueue(.main))
    if isVisible { hide() } else { show() }

  -- MARK: - Window Access

  -- Expose window ID for Phase 3 blacklisting
  var windowNumber: Int?
    return window?.windowNumber

  -- Expose window for Phase 3 cell assignment
  var panelWindow: NSWindow?
    return window
```

## Design Notes

### Why NSWindow with `.titled` style mask
NSPanel windows and borderless windows may not appear in CGWindowListCopyWindowInfo depending on macOS version and configuration. Using `.titled` with hidden title bar ensures the window is a "real" window that the reconciler can discover. The `.fullSizeContentView` style lets us draw over the entire frame.

### Filter mode and first responder
In normal mode, the window itself is the first responder, so keyDown fires on the window. When entering filter mode, the SwiftUI @FocusState directs focus to the TextField. Key events go to the TextField instead of the window. The TextField's .onSubmit (Enter) and .onExitCommand (Escape) handle exiting filter mode. This avoids the NSTextFieldDelegate approach used by the picker -- SwiftUI handles it natively.

### Actor bridging
The NotificationStore is an actor. The view model is @MainActor. All store calls use `Task { await store.method() }`. After each mutation, `refreshNotifications()` is called to re-query the sorted/filtered list. This is a pull model -- the view model polls the store after each action. For Phase 4 (event-driven notifications), we may add a push mechanism (AsyncSequence or callback).

### Key code mapping
macOS key codes used:
- j=38, k=40, d=2, x=7, p=35, g=5, V=9 (with Shift), /=44
- Return=36, Escape=53
- +=24 (with Shift), -=27 (without Shift)

### Scroll management
Using SwiftUI's ScrollViewReader with .scrollTo() and .onChange(of: selectedIndex) for scroll tracking. This is simpler than the AppKit-based manual scroll offset tracking in PickerState because SwiftUI handles the layout.

## PRE-GATE Status
- [x] Discovery complete
- [x] Assumption verified (vim keybinding interception via NSWindow.keyDown)
- [x] Design-it-twice applied to 3 architectural decisions
- [x] Color palette designed with rationale grounded in color theory
- [x] Pseudocode complete for all 5 files
- [x] Ready for implementation
