# List Picker Implementation Plan

> **For Agents:** Invoke `code-foundations` before starting each task.

**Goal:** A generic Telescope-style fuzzy list picker that accepts items, renders a popup UI centered on mouse, and returns the selected item to the caller.

**Approach:** Build a Swift overlay window (SkyLight) with CoreGraphics rendering, keyboard+mouse input handling, and multi-field fuzzy matching. Expose via JSON-RPC so CLI can invoke it with any list of items.

**Execution Mode:** Single agent, sequential tasks

---

## Task 1: Picker Overlay Window (Foundation)

**Outcome:** A SkyLight overlay window that appears centered on the mouse cursor.

**Files:**
- Create: `grid-server/Sources/GridServer/Picker/PickerWindow.swift`

**Steps:**
1. Create `PickerWindow` class modeled on `BorderWindow`
2. Use SkyLight APIs to create a floating, transparent overlay
3. Get current mouse position via `NSEvent.mouseLocation`
4. Implement `show(size: CGSize)` - positions window centered on mouse
5. Implement `hide()` - dismisses window
6. Add basic CoreGraphics context setup for drawing
7. Test: trigger from a temporary RPC endpoint, verify window appears at cursor

**Success:** A blank overlay window appears centered on mouse cursor and can be dismissed.

---

## Task 2: Picker Renderer (Visual Layer)

**Outcome:** CoreGraphics rendering with all visual properties centralized in a configurable `PickerStyle`.

**Files:**
- Create: `grid-server/Sources/GridServer/Picker/PickerStyle.swift`
- Create: `grid-server/Sources/GridServer/Picker/PickerRenderer.swift`

**Steps:**
1. Create `PickerStyle` struct with all visual config:
   ```swift
   struct PickerStyle {
       // Dimensions
       var width: CGFloat
       var maxVisibleItems: Int
       var itemHeight: CGFloat
       var inputHeight: CGFloat
       var padding: CGFloat

       // Typography
       var fontName: String
       var fontSize: CGFloat
       var inputFontSize: CGFloat

       // Colors
       var backgroundColor: NSColor
       var inputBackgroundColor: NSColor
       var textColor: NSColor
       var selectedBackgroundColor: NSColor
       var matchHighlightColor: NSColor
       var cursorColor: NSColor

       // Shape
       var cornerRadius: CGFloat

       static var `default`: PickerStyle { ... }
   }
   ```
2. Define `PickerState` struct (query, items, filtered results, selected index, scroll offset)
3. Create `PickerRenderer.draw(in:, bounds:, state:, style:)` - all drawing uses style values
4. Draw background, input field, results list, selection highlight, match highlights
5. Handle scroll offset for overflow

**Success:** Changing any value in `PickerStyle` updates the appearance. No hardcoded visual values in renderer.

---

## Task 3: Input Handling (Keyboard + Mouse)

**Outcome:** Capture and process keyboard and mouse events to control the picker.

**Files:**
- Create: `grid-server/Sources/GridServer/Picker/PickerInputHandler.swift`

**Steps:**
1. Create `PickerInputHandler` class with event monitor setup
2. Add global keyboard event monitor (NSEvent.addGlobalMonitorForEvents)
3. Handle text input → update query string, trigger re-filter
4. Handle navigation keys:
   - `↑`/`k` or `ctrl-p` → select previous
   - `↓`/`j` or `ctrl-n` → select next
   - `Enter` → confirm selection
   - `Escape` → cancel/dismiss
5. Add local mouse event monitor for clicks within picker window
6. Handle mouse click on item → select and confirm
7. Handle scroll wheel → adjust scroll offset
8. Define `PickerInputDelegate` protocol for callbacks:
   ```swift
   protocol PickerInputDelegate: AnyObject {
       func queryChanged(_ query: String)
       func selectionMoved(_ direction: Int)
       func selectionConfirmed()
       func pickerCancelled()
       func itemClicked(at index: Int)
   }
   ```

**Success:** Typing filters the list, arrows/j/k navigate, Enter confirms, Escape dismisses, mouse clicks work.

---

## Task 4: Fuzzy Matcher (Multi-field Search)

**Outcome:** Fuzzy matching algorithm that searches across multiple fields and returns match positions for highlighting.

**Files:**
- Create: `grid-server/Sources/GridServer/Picker/FuzzyMatcher.swift`

**Steps:**
1. Define `MatchResult` struct:
   ```swift
   struct MatchResult {
       let item: PickerItem
       let score: Int
       let matchedRanges: [Range<String.Index>]  // for highlighting
   }
   ```
2. Create `FuzzyMatcher` with `match(query:, items:) -> [MatchResult]`
3. Implement character-by-character fuzzy matching (fzf-style):
   - Characters must appear in order but not consecutively
   - Smart case (case-insensitive unless query has uppercase)
4. Score matches by:
   - Consecutive character runs (higher)
   - Match at word boundaries (higher)
   - Earlier match position (higher)
5. Search across all `searchable` fields, take best score per item
6. Return results sorted by score descending
7. Track matched character indices for highlight rendering

**Success:** Given query "git" and items with searchable fields, returns scored matches with highlight positions.

---

## Task 5: Picker Manager (Orchestrator)

**Outcome:** Coordinates the picker lifecycle - ties together window, renderer, input handler, and matcher.

**Files:**
- Create: `grid-server/Sources/GridServer/Picker/PickerManager.swift`
- Create: `grid-server/Sources/GridServer/Picker/PickerItem.swift`

**Steps:**
1. Define `PickerItem` struct:
   ```swift
   struct PickerItem: Codable {
       let id: String
       let display: String
       let searchable: [String]
       let metadata: [String: String]?  // passed back, picker ignores
   }
   ```
2. Define `PickerResult` enum:
   ```swift
   enum PickerResult {
       case selected(PickerItem)
       case cancelled
   }
   ```
3. Create `PickerManager` as the main entry point:
   ```swift
   func show(items: [PickerItem], style: PickerStyle?) async -> PickerResult
   ```
4. On `show()`: create window at mouse position, start input handler, render initial state
5. Implement `PickerInputDelegate` - on query change, re-run fuzzy matcher, re-render
6. On selection confirmed, return `.selected(item)` and clean up
7. On cancel, return `.cancelled` and clean up
8. Handle edge cases: empty list, no matches, single item

**Success:** `PickerManager.show(items:)` displays picker, returns selection or cancellation.

---

## Task 6: RPC Integration

**Outcome:** Expose the picker to CLI via JSON-RPC `picker.show` method.

**Files:**
- Modify: `grid-server/Sources/GridServer/MessageHandler.swift`
- Create: `grid-server/Sources/GridServer/Picker/PickerRequest.swift`

**Steps:**
1. Define request/response types:
   ```swift
   struct PickerShowRequest: Codable {
       let items: [PickerItem]
       let style: PickerStyle?  // optional overrides
   }

   struct PickerShowResponse: Codable {
       let selected: PickerItem?  // nil if cancelled
       let cancelled: Bool
   }
   ```
2. Add `picker.show` case to `MessageHandler` routing
3. Handler calls `await PickerManager.shared.show(items:style:)`
4. Convert `PickerResult` to `PickerShowResponse`
5. Return response to caller

**Success:** CLI can send `picker.show` RPC with items, receives selected item or cancellation.

---

## Task 7: CLI Client Integration

**Outcome:** Go CLI can invoke the picker and receive the result.

**Files:**
- Create: `grid-cli/client/picker.go`
- Create: `grid-cli/cmd/picker.go` (test command)

**Steps:**
1. Define Go structs matching the RPC types:
   ```go
   type PickerItem struct {
       ID         string            `json:"id"`
       Display    string            `json:"display"`
       Searchable []string          `json:"searchable"`
       Metadata   map[string]string `json:"metadata,omitempty"`
   }

   type PickerResult struct {
       Selected  *PickerItem `json:"selected"`
       Cancelled bool        `json:"cancelled"`
   }
   ```
2. Add `client.ShowPicker(items []PickerItem) (*PickerResult, error)` method
3. Create temporary `thegrid picker` test command:
   - Hardcode a few sample items
   - Call `ShowPicker()`, print the result
4. Test end-to-end: run command, picker appears, select item, see result in terminal

**Success:** `thegrid picker` opens picker with test items, selection prints to stdout.

---

## Task 8: Configuration Integration

**Outcome:** PickerStyle can be customized via config file.

**Files:**
- Modify: `grid-server/Sources/GridServer/Config/ServerConfig.swift`

**Steps:**
1. Add `picker` section to `ServerConfig`:
   ```yaml
   picker:
     width: 600
     maxVisibleItems: 10
     fontSize: 14
     backgroundColor: "#1e1e2e"
     # ... etc
   ```
2. Load picker config on server startup
3. Merge with `PickerStyle.default` (config overrides defaults)
4. Pass merged style to `PickerManager`

**Success:** User can customize picker appearance via config file.

---

## Task 9: Validation

**Outcome:** End-to-end verification that the picker works correctly.

**Steps:**
1. Build server with `make dev`
2. Run `thegrid picker` test command
3. Verify:
   - Picker appears centered on mouse cursor
   - Typing filters the list
   - j/k and arrows navigate selection
   - Enter returns selected item to CLI
   - Escape cancels and returns cancellation
   - Mouse click selects item
   - Scroll works for long lists
4. Test edge cases: empty query, no matches, single item, very long list

**Success:** All interactions work as expected, result returned to CLI.

---

## Validation

**How to verify the full plan worked:**
- [ ] `thegrid picker` command opens a picker overlay centered on mouse
- [ ] Typing filters the list with fuzzy matching
- [ ] Keyboard navigation (j/k, arrows) and Enter/Escape work
- [ ] Mouse click selects items
- [ ] Selected item is returned to CLI and printed
- [ ] Picker style can be customized via config
