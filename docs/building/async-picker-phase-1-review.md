# Phase 1 Review: Picker UI in Server + Window Source

Reviewer: post-gate (correctness only)
Date: 2026-03-06

---

## 1. Requirements Coverage

### PickerModels.swift — PASS

All four types are present and match the spec:

- `PickerItem`: Codable, Equatable, all fields present (`id/title/subtitle/preview/icon/searchable/metadata/priority`), `display` computed property, memberwise init with correct defaults, backwards-compat Decodable init (prefers `title`, falls back to `display`), Encodable includes both `title` and `display`, `CodingKeys` enum, `allSearchableText` computed property.
- `MatchResult`: `item/score/matchedIndices` fields present.
- `PickerAction`: `focusWindow` and `openApp` cases, `from(metadata:)` parses exactly as specified including guard chains for pid/windowID/bundleID.
- `PickerResult`: `selected` and `cancelled` cases.

One minor observation: the spec says `searchable` defaults to `[title]` in the memberwise init. The implementation uses `searchable ?? [title]` which achieves the same result for the optional parameter form. Correct.

### FuzzyMatcher.swift — PASS

- `FieldType` enum with correct weights: title/searchable=1.0, subtitle=0.7, preview=0.5.
- `match(query:items:)`: empty query returns all items with score=0; smart case (uppercase detection); iterates all fields; applies field weight; captures title indices; adds `priority / 3` bonus; sorts by score desc then display asc.
- `matchSingle(query:text:caseSensitive:)`: normalizes `-` and `_` to space; character-by-character match; base=10; consecutive bonus = `consecutiveCount * 5`; word boundary=+15; camelCase=+10; start=+20; penalty `-textIndex/5`; shorter text bonus `max(0, 100-text.count)`; exact match+500; prefix match+200.

All scoring constants match the pseudocode exactly.

### PickerState.swift — PASS

All ported methods present: `init(items:)`, `updateQuery`, `moveSelection`, `selectedItem`, `selectedResult`, `visibleResults`, `hasItems`, `isListMode`, `resetWithItems`. Private helpers `findScrollOffsetToShow` and `countVisibleItemsFrom` are present.

`appendItems()` matches the spec exactly:
- Builds `Set` of existing IDs.
- Filters duplicates, guards on empty unique set.
- Appends, preserves selection identity by ID.
- Re-filters against current query.
- Restores `selectedIndex` by ID lookup, adjusts scroll offset with the two-condition check (above/below visible area).
- Falls back to clamped index when previous selection not found.
- Fires `onStateChange`.

### PickerViews.swift — PASS

All renames applied:
- `Colors` -> `PickerColors` (all 8 color constants present with exact values).
- `Fonts` -> `PickerFonts` (BerkeleyMono fallback to `monospacedSystemFont`).
- `BackgroundView` -> `PickerBackgroundView` (rounded rect fill + border stroke, `acceptsFirstMouse` returns true).
- `ListView` -> `PickerListView` (weak state ref, `itemViews`, `refresh`, `requiredHeight`, `shouldShowEmptyMessage`).

`NSLabel`, `IconRenderer`, `ListItemView` carry no renames as specified. All `Colors.` references in `ListItemView` and `PickerBackgroundView` use `PickerColors.`; all `Fonts.` references use `PickerFonts.`. `IconRenderer` correctly has no Colors/Fonts references of its own.

### PickerWindow.swift — PASS

- No `PickerConfig` — width hardcoded to 800, always list mode. Correct.
- `spinner: NSProgressIndicator` present, `.spinning` style, `.small` size, `isDisplayedWhenStopped = false`.
- `onResult: ((PickerResult) -> Void)?` callback present.
- `resetForNewShow()` clears text, calls `state.resetWithItems([])`, recenters.
- `getState() -> PickerState` present.
- `setLoading(_:)` starts/stops spinner animation.
- `recenterOnMouseScreen()` implemented, finds mouse screen with fallback to `NSScreen.main`.
- `keyDown`: ESC (53) fires `.cancelled`; down arrow (125) / Ctrl-n; up arrow (126) / Ctrl-p. `j/k` removed as specified.
- `NSTextFieldDelegate`: `insertNewline` -> `submit()`, `cancelOperation` -> `.cancelled`, `moveDown`/`moveUp` -> `moveSelection`.
- `canBecomeKey: true`, `canBecomeMain: false`.

Note: `NSTextFieldDelegate` is implemented as an extension rather than declared in the class header. The pseudocode shows it in the class signature as `class PickerWindow: NSWindow, NSTextFieldDelegate`. The extension form is functionally identical and preferred Swift style. Not a defect.

### PickerManager.swift — PASS

- Singleton with `static let shared`, `private init()`.
- State variables: `window`, `discoveryTask`, `isVisible`, `isActivating`, `activationGraceTimer`.
- `show()`: toggle behavior (visible -> hide), lazy window creation, `onResult` callback wired, `didResignKeyNotification` observer registered once, `resetForNewShow`, `setLoading(true)`, grace period set before policy switch, `setActivationPolicy(.regular)`, `makeKeyAndOrderFront`, `activate`, `focusInput`, 200ms grace timer, `discoveryTask` launched.
- `hide()`: `dispatchPrecondition`, guard on `isVisible`, cancels task, `orderOut`, `setLoading(false)`, `.prohibited` policy.
- `handleResult()`: hides first, then executes action on `.selected`, no-op on `.cancelled`.
- `executeAction()`: `PickerAction.from(metadata:)` with no-action log, `focusWindow` uses `SLSMainConnectionID()`/`WindowManipulator`, `openApp` uses `NSWorkspace.openApplication`.
- `discoverAndStream()`: `TaskGroup`, error catch returns `[]` with log, cancellation check before `MainActor.run`, `appendItems` called on main, spinner stopped after group completes.
- `windowDidResignKey`: grace period guard, calls `handleResult(.cancelled)`.

### PickerSource.swift — PASS

Protocol exactly as specified: `id: String`, `discover() async throws -> [PickerItem]`.

### WindowSource.swift — PASS

- Reads `StateManager.shared.getState()` via `await`.
- Filters: `isHidden`, `isMinimized`, `alpha > 0.01`, subrole guard (`AXStandardWindow` or nil).
- `appName` lookup: `window.appName ?? app?.localizedName ?? "Unknown"`.
- Title construction: `"AppName — WindowTitle"` or just `appName`.
- `icon` from `bundleID.map { "bundle:\($0)" }`.
- `searchable`: appName + windowTitle (if non-empty) + bundleID (if present).
- `metadata`: `action/pid/windowID` always; `bundleID` conditional.
- `id`: `"win-\(windowIDStr)"`.
- `priority: 1000`.
- Sorted by title `localizedCaseInsensitiveCompare`.

### BFDManager.swift — PASS

`onHotkeyTriggered` now trims whitespace, checks `hasPrefix("@")`, calls `handleInternalCommand` and returns early, otherwise falls through to `executeAsync`.

`handleInternalCommand`:
- `@pick` dispatches `PickerManager.shared.show()` on `DispatchQueue.main.async`, logs `bfd.internal`.
- `default` logs `bfd.err.internal` with cmd, hotkey, and msg fields.

One deviation from pseudocode: the spec showed `"msg": "unknown @ command"` only, but the implementation also includes `"hotkey": hotkey` in the default error log. This is additive (more information), not a defect.

---

## 2. Concurrency Safety — PASS

- `show()` has `dispatchPrecondition(condition: .onQueue(.main))`. Verified at line 31.
- `hide()` has `dispatchPrecondition(condition: .onQueue(.main))`. Verified at line 90.
- `discoverAndStream()` calls `await MainActor.run { ... }` before touching `window` or calling `appendItems`. Correct.
- `appendItems()` comment says "Must be called on main thread" — all callers route through `MainActor.run`. Consistent.
- `isVisible` and `window` are only accessed on the main thread (guarded by preconditions or `MainActor.run`). No data race.
- Grace timer uses `DispatchWorkItem` on `.main` queue. Safe.

---

## 3. Edge Cases — PASS

- **Toggle (show when visible = hide):** `show()` checks `if isVisible { hide(); return }` at the top. Correct.
- **Grace period:** `isActivating` set to `true` before `setActivationPolicy(.regular)`. `windowDidResignKey` returns early while `isActivating`. Timer clears it after 200ms. Covers the transient resign caused by policy switch.
- **Rapid cancel before grace expires:** `activationGraceTimer?.cancel()` at start of `show()` prevents stale timer from clearing `isActivating` after a second `show()` begins. Correct.
- **Discovery task cancelled before items arrive:** `guard !Task.isCancelled else { break }` before `MainActor.run`. Correct.
- **`appendItems` with empty unique set:** early `return` before `onStateChange`. Avoids spurious UI refresh.
- **Selection preservation across appends:** identity-based restore, clamp fallback. Correct.
- **`recenterOnMouseScreen` fallback chain:** mouse screen -> `NSScreen.main` -> nil (returns without moving). The `init` path has a stronger fallback (`NSScreen.screens.first!`) which is appropriate since the window must be placed somewhere at creation time.

---

## 4. Build Verification — PASS

```
swift build
Build complete! (2.23s)
```

Zero errors, zero warnings.

---

## Overall Verdict: PASS

All nine pseudocode sections are fully implemented. Concurrency safety is correct. Edge cases are handled. Build is clean.
