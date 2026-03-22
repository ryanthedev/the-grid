# Discovery: Phase 2 - NSWindow, SwiftUI views, and vim keybindings

## Files Found

### Phase 1 Outputs (Prerequisites)
- `grid-server/Sources/GridServer/Notifications/Notification.swift` -- GridNotification model, GridNotificationAction, GridNotificationPriority, GridNotificationFilter, GridNotificationStoreData
- `grid-server/Sources/GridServer/Notifications/NotificationStore.swift` -- Actor-based store with CRUD, filtering, bulk ops, debounced persistence

### Reference Pattern Files
- `grid-server/Sources/GridServer/Picker/PickerWindow.swift` -- NSPanel subclass with keyDown override, canBecomeKey/Main, onResult callback
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` -- Singleton orchestrator (main-thread class), show/hide lifecycle, lazy window creation, NSWindow.didResignKeyNotification observer
- `grid-server/Sources/GridServer/Picker/PickerViews.swift` -- PickerColors struct (Ghostty-inspired dark theme), PickerFonts enum, PickerBackgroundView (rounded rect with border stroke), ListItemView, PickerListView
- `grid-server/Sources/GridServer/Picker/PickerState.swift` -- Observable state class with onStateChange callback, query filtering, scroll management
- `grid-server/Sources/GridServer/Borders/SimpleBorderConfig.swift` -- BorderConfigManager singleton with lock-based thread-safe config, parseHexColor, CGColor-based styles
- `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` -- Border lifecycle manager
- `grid-server/Sources/GridServer/TestPanel.swift` -- Minimal NSPanel with keyDown, toggle pattern

### Utility Files
- `grid-server/Sources/GridServer/XDG.swift` -- XDG enum for path resolution

## Current State

### What Exists
- Phase 1 model layer is complete and tested (20 unit tests passing)
- No SwiftUI usage exists anywhere in the codebase -- all UI is pure AppKit (NSView, NSTextField, NSPanel)
- No NSHostingView usage anywhere
- keyDown override pattern is well-established (PickerWindow, TestPanel, GridViewer)
- Manager singleton pattern established (PickerManager, SimpleBorderManager, ResizeManager, BFDManager, BorderConfigManager)
- Dark theme color palette exists in PickerColors (Ghostty-inspired: #121212 background, #232323 input, #BFBFBF text, #00BFFF accent)
- Border defaults: active = red (1.0, 0.0, 0.0), inactive = #666666

### What Does NOT Exist
- No SwiftUI views anywhere in the project
- No NSHostingView wrapper
- No notification panel window
- No notification panel manager
- No notification-specific theme/color configuration

## Gaps

### Gap 1: SwiftUI is new to this codebase
The entire codebase uses pure AppKit for UI. This phase introduces SwiftUI via NSHostingView for the first time. The Package.swift targets macOS 13+, which fully supports SwiftUI. No package changes needed.

### Gap 2: NSWindow vs NSPanel
The plan requires NSWindow (not NSPanel) so the window appears in CGWindowListCopyWindowInfo for cell assignment. All existing custom windows (PickerWindow, TestPanel) use NSPanel. The notification panel will be the first standard NSWindow subclass.

### Gap 3: Server process activation policy
The server process currently does not register as a `.regular` app (it's a background process). The StateManager filters windows by `.regular` activation policy. For the notification window to be cell-assignable, Phase 3 will need to handle how the reconciler discovers and manages this window. Phase 2 just needs to ensure the window is created correctly as a standard NSWindow.

## Assumption Verification

### Vim keybindings can be intercepted before SwiftUI in NSHostingView (Confidence: MED)

**Finding: The assumption is VALID, and the fallback approach is actually the BETTER primary approach.**

Analysis:
1. NSHostingView is an NSView subclass. It does not override keyDown in a way that prevents its superview or window from intercepting keys first.
2. The AppKit responder chain flows: First Responder -> Views up the hierarchy -> Window -> Application. The NSWindow's `keyDown(with:)` override fires BEFORE events reach SwiftUI content.
3. However, the cleanest approach (per established codebase patterns) is: **override `keyDown` on the NSWindow subclass itself**. This is exactly what PickerWindow and TestPanel already do. The window is the responder chain owner.
4. For the notification panel, unlike the picker (which has a text field as first responder), the notification panel has no text input in normal mode. The window itself should be the first responder for vim keys.
5. Filter mode (/) will temporarily make a text field the first responder. The NSTextFieldDelegate pattern (see PickerWindow's `control(_:textView:doCommandBy:)`) handles intercepting Enter/Escape during text editing.

**Conclusion:** Override `keyDown` on the NSWindow subclass. No custom NSView wrapper needed. This matches existing patterns perfectly.

## Prerequisites
- [x] Phase 1 complete (notification model and store)
- [x] AppKit window creation pattern established
- [x] keyDown override pattern established
- [x] Dark theme color palette available for reference
- [x] macOS 13+ supports SwiftUI (Package.swift already targets .macOS(.v13))
- [x] Manager singleton pattern established

## Recommendation
**BUILD**

All prerequisites are met. The plan's uncertainty (vim keybinding interception) is resolved -- the NSWindow keyDown override approach is proven in the codebase. SwiftUI is new but Package.swift already targets a compatible macOS version.

Key implementation decisions:
1. NSWindow subclass (not NSPanel) with `keyDown` override for vim keys
2. NSHostingView embedded as contentView for SwiftUI rendering
3. Manager class (not actor) following PickerManager pattern -- main-thread, dispatchPrecondition
4. ObservableObject view model bridging NotificationStore (actor) to SwiftUI (@Published)
5. Theme colors as a simple struct with defaults, configurable at init time
