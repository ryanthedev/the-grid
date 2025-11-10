# Window-to-Space Movement API Specification

**Document Version**: 1.0
**Target Platform**: macOS 11.0+ (Big Sur through Tahoe/26.x)
**Source**: yabai window manager codebase
**Purpose**: Complete reference for moving windows between spaces/desktops in macOS

---

## Table of Contents

1. [Overview](#1-overview)
2. [Command Syntax](#2-command-syntax)
3. [Private APIs](#3-private-apis)
4. [Implementation Flow](#4-implementation-flow)
5. [Privilege Requirements](#5-privilege-requirements)
6. [Constraints and Limitations](#6-constraints-and-limitations)
7. [Space Selectors](#7-space-selectors)
8. [Related Operations](#8-related-operations)
9. [Query APIs](#9-query-apis)
10. [Code Examples](#10-code-examples)
11. [Swift Implementation Guide](#11-swift-implementation-guide)
12. [File Reference Map](#12-file-reference-map)

---

## 1. Overview

**YES - yabai fully supports moving windows between spaces (desktops) in macOS.**

### Feature Summary

- ✅ Move single windows to any user space
- ✅ Move multiple windows in batch operations
- ✅ Move across displays (different monitors)
- ✅ Flexible space selection (index, label, relative, cursor)
- ✅ Automatic focus management
- ✅ BSP tree re-tiling on destination space
- ✅ Works with minimized and floating windows
- ❌ Cannot move to macOS fullscreen spaces

### Architecture

```
User Command
     │
     ▼
┌────────────────────────────────────────────────┐
│  message.c: Parse --space SPACE_SEL            │
│  - Validate space selector                     │
│  - Resolve to space ID (uint64_t)              │
│  - Check if fullscreen space                   │
└────────────────┬───────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────┐
│  window_manager.c: send_window_to_space()      │
│  - Manage focus (find next window)             │
│  - Untile from source space BSP tree           │
│  - Call low-level space move                   │
│  - Re-tile on destination space                │
└────────────────┬───────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────┐
│  space_manager.c: move_window_to_space()       │
│  - Version detection                           │
│  - Choose API method                           │
│  ├─ Modern macOS: Scripting Addition          │
│  ├─ Older macOS: Direct SkyLight API          │
│  └─ Fallback: Compatibility workspace IDs     │
└────────────────┬───────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────┐
│  SkyLight Framework (Private API)              │
│  SLSMoveWindowsToManagedSpace(cid, wids, sid)  │
│  - Executes actual window space transition     │
└────────────────────────────────────────────────┘
```

---

## 2. Command Syntax

### Basic Command

```bash
yabai -m window [WINDOW_SEL] --space SPACE_SEL
```

### Examples

```bash
# Move focused window to space 2
yabai -m window --space 2

# Move window 42 to space labeled "code"
yabai -m window 42 --space code

# Move focused window to previous space
yabai -m window --space prev

# Move focused window to next space
yabai -m window --space next

# Move window to first space
yabai -m window --space first

# Move window to last space
yabai -m window --space last

# Move window to recently focused space
yabai -m window --space recent

# Move window to space under cursor
yabai -m window --space mouse
```

### Alternative: Move to Display

Moving to a display implicitly moves to the active space on that display:

```bash
# Move to active space on display 1
yabai -m window --display 1

# Move to display containing cursor
yabai -m window --display mouse

# Move to next display
yabai -m window --display next
```

### Command Definition

**Source**: `/Users/r/repos/yabai/src/message.c:135`

```c
#define COMMAND_WINDOW_SPACE "--space"
#define COMMAND_WINDOW_DISPLAY "--display"
```

---

## 3. Private APIs

### 3.1 Primary API: SLSMoveWindowsToManagedSpace

**Function**: `SLSMoveWindowsToManagedSpace`
**Framework**: SkyLight.framework (Private)
**Declaration**: `/Users/r/repos/yabai/src/misc/extern.h:61`

```c
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);
```

#### Parameters

- **`cid`** (int): Connection ID to window server
  - Obtained via `SLSMainConnectionID()`
  - Represents connection to CoreGraphics window server

- **`window_list`** (CFArrayRef): Array of window IDs
  - Array of CFNumbers containing uint32_t window IDs
  - Can contain single or multiple windows
  - Created via `cfarray_of_cfnumbers()`

- **`sid`** (uint64_t): Target space ID
  - 64-bit space identifier
  - Not Mission Control index (internal ID)

#### Return Value

- **void**: No return value, no error checking possible
- Failures are silent (window may not move)

#### Usage Conditions

**Works on**:
- macOS 11.0 - 12.6
- macOS 13.0 - 13.5
- macOS 14.0 - 14.4

**Requires Scripting Addition on**:
- macOS 12.7+
- macOS 13.6+
- macOS 14.5+
- macOS 15.0+ (Sequoia)
- macOS 26.0+ (Tahoe)

#### Example

```c
// Move single window
uint32_t wid = 12345;
CFArrayRef window_list = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
SLSMoveWindowsToManagedSpace(g_connection, window_list, target_sid);
CFRelease(window_list);

// Move multiple windows
uint32_t wids[] = {12345, 67890, 11111};
CFArrayRef window_list = cfarray_of_cfnumbers(wids, sizeof(uint32_t), 3, kCFNumberSInt32Type);
SLSMoveWindowsToManagedSpace(g_connection, window_list, target_sid);
CFRelease(window_list);
```

---

### 3.2 Scripting Addition Interface (Modern macOS)

**Purpose**: Inject code into Dock.app to execute privileged operations
**Required on**: macOS 12.7+, 13.6+, 14.5+, 15.0+

#### Opcodes

**Source**: `/Users/r/repos/yabai/src/osax/common.h:35-36`

```c
enum sa_opcode {
    // ... other opcodes ...
    SA_OPCODE_WINDOW_LIST_TO_SPACE  = 0x12,  // Batch move
    SA_OPCODE_WINDOW_TO_SPACE       = 0x13,  // Single move
};
```

#### Client-Side Functions

**Source**: `/Users/r/repos/yabai/src/sa.h:28-29`

```c
bool scripting_addition_move_window_to_space(uint64_t sid, uint32_t wid);
bool scripting_addition_move_window_list_to_space(uint64_t sid, uint32_t *window_list, int window_count);
```

**Implementation**: `/Users/r/repos/yabai/src/sa.m:605-622`

```c
bool scripting_addition_move_window_to_space(uint64_t sid, uint32_t wid)
{
    // Pack space ID and window ID into payload
    // Send to scripting addition via socket
    // SA executes SLSMoveWindowsToManagedSpace from within Dock.app
    return sa_payload_send(SA_OPCODE_WINDOW_TO_SPACE);
}

bool scripting_addition_move_window_list_to_space(uint64_t sid, uint32_t *window_list, int window_count)
{
    // Pack space ID, window count, and window IDs
    // Send batch operation to SA
    return sa_payload_send(SA_OPCODE_WINDOW_LIST_TO_SPACE);
}
```

#### Payload Handler (Inside Dock.app)

**Source**: `/Users/r/repos/yabai/src/osax/payload.m:920-931`

```c
static void do_window_move_to_space(char *message)
{
    // Unpack space ID
    uint64_t sid;
    unpack(sid);

    // Unpack window ID
    uint32_t wid;
    unpack(wid);

    // Create CFArray with single window
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);

    // Execute from within Dock.app process (has required privileges)
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list_ref, sid);

    CFRelease(window_list_ref);
}
```

#### Why Scripting Addition is Required

On modern macOS versions, `SLSMoveWindowsToManagedSpace` requires:
1. **Code injection into Dock.app**, or
2. **Running from Dock.app process context**

The scripting addition (`yabai.osax`) provides this by:
- Installing into `/Library/ScriptingAdditions/yabai.osax`
- Being automatically loaded by Dock.app on launch
- Providing socket-based RPC interface
- Executing privileged APIs from Dock's process space

---

### 3.3 Fallback: Compatibility Workspace IDs

**Used when**: Scripting addition unavailable on modern macOS

**APIs**: `/Users/r/repos/yabai/src/misc/extern.h:94-95`

```c
extern void SLSSpaceSetCompatID(int cid, uint64_t sid, uint32_t compatibility_id);
extern void SLSSetWindowListWorkspace(int cid, uint32_t *window_list, int window_count, uint32_t compatibility_id);
```

#### Implementation

**Source**: `/Users/r/repos/yabai/src/space_manager.c:677-681`

```c
// Assign temporary compatibility ID to target space
SLSSpaceSetCompatID(g_connection, sid, 0x79616265);  // 'yabe' in ASCII

// Move windows to workspace with that compatibility ID
SLSSetWindowListWorkspace(g_connection, &window->id, 1, 0x79616265);

// Clear compatibility ID
SLSSpaceSetCompatID(g_connection, sid, 0x0);
```

#### Magic Number: `0x79616265`

```c
0x79616265 = 'yabe' (ASCII)
// y = 0x79
// a = 0x61
// b = 0x62
// e = 0x65
```

**Purpose**: Unique identifier to prevent conflicts with other workspace IDs

#### Limitations

- Less reliable than direct `SLSMoveWindowsToManagedSpace`
- May not work on all macOS versions
- Compatibility ID may conflict if not properly cleared
- Used as last resort

---

### 3.4 Version Detection

**Function**: `workspace_use_macos_space_workaround()`
**Source**: `/Users/r/repos/yabai/src/workspace.m:17-26`

```c
bool workspace_use_macos_space_workaround(void)
{
    NSOperatingSystemVersion os_version = [[NSProcessInfo processInfo] operatingSystemVersion];

    // Monterey 12.7+
    if (os_version.majorVersion == 12 && os_version.minorVersion >= 7) return true;

    // Ventura 13.6+
    if (os_version.majorVersion == 13 && os_version.minorVersion >= 6) return true;

    // Sonoma 14.5+
    if (os_version.majorVersion == 14 && os_version.minorVersion >= 5) return true;

    // Sequoia 15.0+ and Tahoe 26.0+
    return os_version.majorVersion >= 15;
}
```

**Returns**:
- `true`: Use scripting addition (modern macOS)
- `false`: Use direct `SLSMoveWindowsToManagedSpace` (older macOS)

---

### 3.5 Related Query APIs

#### Get Window's Current Space

**Source**: `/Users/r/repos/yabai/src/misc/extern.h:21`

```c
extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
```

**Parameters**:
- `cid`: Connection ID
- `selector`: `0x7` (magic value for "all spaces")
- `window_list`: CFArray of window IDs

**Returns**: CFArray of space IDs (one per window)

#### Get Windows on Space

**Source**: `/Users/r/repos/yabai/src/misc/extern.h:22`

```c
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces,
                                                   uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);
```

**Usage**:
```c
CFArrayRef space_list = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
CFArrayRef window_list = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_list, 0x2, NULL, NULL);
```

#### Check Space Type

**Source**: `/Users/r/repos/yabai/src/misc/extern.h:54`

```c
extern int SLSSpaceGetType(int cid, uint64_t sid);
```

**Returns**:
- `0`: User space (normal desktop)
- `2`: System space (login window, etc.)
- `4`: Fullscreen space (created by fullscreen app)

---

## 4. Implementation Flow

### 4.1 High-Level Flow

**Entry Point**: `/Users/r/repos/yabai/src/message.c:2138-2146`

```c
else if (token_equals(command, COMMAND_WINDOW_SPACE)) {
    // Parse space selector (index, label, prev, next, etc.)
    struct selector selector = parse_space_selector(rsp, &message,
                                                    space_manager_active_space(),
                                                    false);

    if (selector.did_parse && selector.sid) {
        // Check if target is fullscreen space
        if (space_is_fullscreen(selector.sid)) {
            daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
        } else {
            // Execute window move
            window_manager_send_window_to_space(&g_space_manager,
                                               &g_window_manager,
                                               acting_window,
                                               selector.sid,
                                               false);
        }
    }
}
```

**Key Steps**:
1. Parse space selector to get target space ID
2. Validate space is not fullscreen
3. Call window manager to execute move

---

### 4.2 Window Manager Implementation

**Function**: `window_manager_send_window_to_space()`
**Source**: `/Users/r/repos/yabai/src/window_manager.c:2080-2109`

```c
void window_manager_send_window_to_space(struct space_manager *sm,
                                         struct window_manager *wm,
                                         struct window *window,
                                         uint64_t dst_sid,
                                         bool moved_by_rule)
{
    TIME_FUNCTION;

    // 1. GET SOURCE SPACE
    uint64_t src_sid = window_space(window->id);
    if (src_sid == dst_sid) return;  // Already on target space

    // 2. FOCUS MANAGEMENT
    // If moving window from visible space, focus next window
    if (space_is_visible(src_sid) &&
        (moved_by_rule || wm->focused_window_id == window->id)) {

        // Find next window on source space (by rank)
        struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(
            wm, src_sid, 1, window->id
        );

        if (next) {
            // Focus next window
            window_manager_focus_window_with_raise(&next->application->psn,
                                                  next->id,
                                                  next->ref);
        } else {
            // No windows left, focus Finder
            _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn,
                                           0,
                                           kCPSNoWindows);
        }
    }

    // 3. UNTILE FROM SOURCE SPACE
    // If window is managed in BSP tree, remove it
    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_purify_window(wm, window);
    }

    // 4. EXECUTE SPACE MOVE (Low-level API call)
    space_manager_move_window_to_space(dst_sid, window);

    // 5. RE-TILE ON DESTINATION SPACE
    // If window should be managed, insert into BSP tree
    if (window_manager_should_manage_window(window)) {
        struct view *view = space_manager_tile_window_on_space(sm, window, dst_sid);
        window_manager_add_managed_window(wm, window, view);
    }
}
```

**Key Operations**:
1. **Early exit**: Return if already on target space
2. **Focus management**: Find and focus next window on source space
3. **Untile**: Remove from BSP tree if managed
4. **Move**: Execute low-level space transition
5. **Re-tile**: Insert into BSP tree on destination if eligible

---

### 4.3 Low-Level Space Move

**Function**: `space_manager_move_window_to_space()`
**Source**: `/Users/r/repos/yabai/src/space_manager.c:671-682`

```c
void space_manager_move_window_to_space(uint64_t sid, struct window *window)
{
    if (!workspace_use_macos_space_workaround()) {
        // DIRECT API (macOS < 12.7, < 13.6, < 14.5, < 15.0)
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&window->id,
                                                          sizeof(uint32_t),
                                                          1,
                                                          kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);

    } else if (!scripting_addition_move_window_to_space(sid, window->id)) {
        // FALLBACK (if SA unavailable)
        SLSSpaceSetCompatID(g_connection, sid, 0x79616265);
        SLSSetWindowListWorkspace(g_connection, &window->id, 1, 0x79616265);
        SLSSpaceSetCompatID(g_connection, sid, 0x0);
    }
}
```

**Decision Tree**:
```
Is modern macOS (12.7+, 13.6+, 14.5+, 15.0+)?
├─ No → Use SLSMoveWindowsToManagedSpace directly
└─ Yes → Try scripting addition
         ├─ Success → Done
         └─ Failure → Fall back to compatibility workspace IDs
```

---

### 4.4 Batch Window Move

**Function**: `space_manager_move_window_list_to_space()`
**Source**: `/Users/r/repos/yabai/src/space_manager.c:658-669`

```c
void space_manager_move_window_list_to_space(uint64_t sid,
                                             uint32_t *window_list,
                                             int window_count)
{
    if (!workspace_use_macos_space_workaround()) {
        // DIRECT API - batch move
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(window_list,
                                                          sizeof(uint32_t),
                                                          window_count,
                                                          kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);

    } else if (!scripting_addition_move_window_list_to_space(sid, window_list, window_count)) {
        // FALLBACK - batch move using compatibility IDs
        SLSSpaceSetCompatID(g_connection, sid, 0x79616265);
        SLSSetWindowListWorkspace(g_connection, window_list, window_count, 0x79616265);
        SLSSpaceSetCompatID(g_connection, sid, 0x0);
    }
}
```

**Advantages of Batch Move**:
- Single API call for multiple windows
- Atomic operation (all windows move together)
- Better performance than repeated single moves
- Fewer space transitions/animations

---

## 5. Privilege Requirements

### 5.1 Accessibility Permissions

**Required**: Always
**Purpose**: Window detection, focus management, property queries

**Check**: `/Users/r/repos/yabai/src/yabai.c:270-272`

```c
if (!ax_privilege()) {
    require("yabai: could not access accessibility features! abort..\n");
}
```

**Grant via**:
- System Settings > Privacy & Security > Accessibility
- Add yabai to allowed applications

**Used for**:
- Querying window properties (title, frame, role)
- Managing window focus
- AX observer callbacks
- Window creation/destruction detection

---

### 5.2 Scripting Addition (OSAX)

**Required**: On macOS 12.7+, 13.6+, 14.5+, 15.0+ (Tahoe)
**Purpose**: Execute privileged SkyLight APIs from Dock.app context

#### Installation

**Command**:
```bash
sudo yabai --load-sa
```

**What it does**:
```bash
# 1. Copy payload to system location
sudo cp -r /path/to/yabai.osax /Library/ScriptingAdditions/

# 2. Restart Dock to load scripting addition
killall Dock

# 3. Yabai establishes socket connection to SA
# Socket: /tmp/yabai-sa_<username>.socket
```

**Location**: `/Library/ScriptingAdditions/yabai.osax/`

#### SIP Requirement

**Must disable**: Filesystem protections for `/System` and `/Library`

**Command**:
```bash
# Boot to Recovery Mode (Cmd+R)
csrutil enable --without fs --without debug --without nvram

# Reboot
```

**Check**:
```bash
csrutil status
# Should show: Filesystem Protections: disabled
```

#### Uninstallation

```bash
sudo yabai --uninstall-sa
```

---

### 5.3 Privilege Summary

| Operation | Accessibility | Scripting Addition |
|-----------|--------------|-------------------|
| Query window space | ✅ Required | ❌ Not required |
| Focus window | ✅ Required | ❌ Not required |
| Move window (older macOS) | ✅ Required | ❌ Not required |
| Move window (modern macOS) | ✅ Required | ✅ **Required** |
| Batch move windows | ✅ Required | ✅ Required (modern) |

---

## 6. Constraints and Limitations

### 6.1 Space Type Restrictions

#### Cannot Move to Fullscreen Spaces

**Check**: `/Users/r/repos/yabai/src/message.c:2141-2143`

```c
if (space_is_fullscreen(selector.sid)) {
    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
}
```

**Reason**: Fullscreen spaces (Type 4) are managed exclusively by the fullscreen app

**Workaround**: None - this is a macOS limitation

#### Space Types

**Source**: `/Users/r/repos/yabai/src/space.c:88-101`

```c
bool space_is_user(uint64_t sid)
{
    return SLSSpaceGetType(g_connection, sid) == 0;
}

bool space_is_system(uint64_t sid)
{
    return SLSSpaceGetType(g_connection, sid) == 2;
}

bool space_is_fullscreen(uint64_t sid)
{
    return SLSSpaceGetType(g_connection, sid) == 4;
}
```

**Type Values**:
- **Type 0**: User space (normal desktop) - ✅ Allowed
- **Type 2**: System space (login window, screen saver) - ⚠️ Allowed but not recommended
- **Type 4**: Fullscreen space - ❌ Blocked

---

### 6.2 Window State Handling

#### Sticky Windows

**Definition**: Windows visible on all spaces

**Behavior**:
- Can be moved to specific space
- Loses sticky status after move
- Must explicitly re-enable sticky if desired

**Related API**:
```c
bool scripting_addition_set_sticky(uint32_t wid, bool value);
```

#### Minimized Windows

**Behavior**:
- Can be moved between spaces
- Remain minimized after move
- Still tracked in space's window list
- Included in batch operations

**Query**:
```c
bool window_is_minimized(struct window *window);
```

#### Floating Windows

**Behavior**:
- Moved without BSP tree operations
- No untiling/re-tiling
- Maintain floating status on destination
- Position preserved relative to screen

**Check**:
```c
bool window_manager_find_managed_window(struct window_manager *wm, struct window *window);
// Returns NULL if floating
```

#### Managed Windows

**Behavior**:
- Untiled from source space BSP tree
- Space transition executes
- Re-tiled on destination space
- May change size/position based on destination layout

**Re-tile Logic**:
```c
if (window_manager_should_manage_window(window)) {
    struct view *view = space_manager_tile_window_on_space(sm, window, dst_sid);
    window_manager_add_managed_window(wm, window, view);
}
```

---

### 6.3 Display Boundaries

#### Same Display Move

**Behavior**:
- Direct space transition
- No coordinate transformation
- Instant (no cross-display animation)

**Example**:
```
Display 1: [Space 1] [Space 2] [Space 3]
Window on Space 1 → Space 3
```

#### Cross-Display Move

**Behavior**:
- Window automatically repositioned to destination display
- Coordinate system transforms automatically
- Size maintained (unless re-tiled)
- No explicit display parameter needed

**Example**:
```
Display 1: [Space 1] [Space 2]
Display 2: [Space 3] [Space 4]
Window on Space 1 → Space 4
Result: Window now on Display 2, Space 4
```

**Implementation Note**:
Space IDs are globally unique across displays. Moving to a space on a different display automatically handles the display transition.

---

### 6.4 Focus Behavior

#### When Moving Focused Window

**If source space is visible**:
1. Find next window on source space (by rank)
2. Focus next window
3. If no windows remain, focus Finder

**Implementation**: `/Users/r/repos/yabai/src/window_manager.c:2085-2096`

```c
if (space_is_visible(src_sid) &&
    (moved_by_rule || wm->focused_window_id == window->id)) {

    struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(
        wm, src_sid, 1, window->id
    );

    if (next) {
        window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
    } else {
        _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
    }
}
```

#### When Moving Non-Focused Window

**Behavior**:
- No focus changes
- Current focused window remains focused
- Moved window loses focus if it had it

---

## 7. Space Selectors

### 7.1 Selector Syntax

**General Form**: `SPACE_SEL`

**Types**:
1. Mission Control index (integer)
2. Label (string identifier)
3. Relative position (keyword)
4. Cursor location (keyword)

### 7.2 By Mission Control Index

**Syntax**: Positive integer

```bash
yabai -m window --space 1   # First space (across all displays)
yabai -m window --space 2   # Second space
yabai -m window --space 5   # Fifth space
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:793-801`

```c
if (token_is_valid(token)) {
    int sid_val;
    if (sscanf(token, "%d", &sid_val) == 1) {
        // Get space by Mission Control index
        selector.sid = space_manager_mission_control_space(sid_val);
        selector.did_parse = true;
    }
}
```

**Notes**:
- Index is 1-based
- Spans all displays (not per-display)
- Order determined by Mission Control configuration
- Invalid index silently fails

---

### 7.3 By Label

**Syntax**: String label (alphanumeric)

```bash
# Set label
yabai -m space 1 --label work

# Move to labeled space
yabai -m window --space work
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:830-838`

```c
if (token_is_valid(token)) {
    // Look up space by label
    selector.sid = space_manager_find_space_by_label(&g_space_manager, token);
    if (selector.sid) {
        selector.did_parse = true;
    }
}
```

**Implementation**: `/Users/r/repos/yabai/src/space_manager.c`

```c
uint64_t space_manager_find_space_by_label(struct space_manager *sm, char *label)
{
    // Hash table lookup: label → space ID
    struct space_label *sl = table_find(&sm->labels, label);
    return sl ? sl->sid : 0;
}
```

**Notes**:
- Labels are user-defined
- Case-sensitive
- Must be unique
- Persistent across yabai restarts (stored in config)

---

### 7.4 Relative Selectors

#### Previous Space

**Syntax**: `prev`

```bash
yabai -m window --space prev
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:810-814`

```c
if (token_equals(token, ARGUMENT_SPACE_SEL_PREV)) {
    selector.sid = space_manager_prev_space(acting_sid);
    selector.did_parse = true;
}
```

**Behavior**:
- Gets previous space in Mission Control order
- Wraps to last space if currently on first
- Includes spaces on all displays

---

#### Next Space

**Syntax**: `next`

```bash
yabai -m window --space next
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:816-820`

```c
if (token_equals(token, ARGUMENT_SPACE_SEL_NEXT)) {
    selector.sid = space_manager_next_space(acting_sid);
    selector.did_parse = true;
}
```

**Behavior**:
- Gets next space in Mission Control order
- Wraps to first space if currently on last
- Includes spaces on all displays

---

#### First Space

**Syntax**: `first`

```bash
yabai -m window --space first
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:822-826`

```c
if (token_equals(token, ARGUMENT_SPACE_SEL_FIRST)) {
    selector.sid = space_manager_first_space();
    selector.did_parse = true;
}
```

**Behavior**:
- Returns first space across all displays
- Based on Mission Control ordering

---

#### Last Space

**Syntax**: `last`

```bash
yabai -m window --space last
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:828-832`

```c
if (token_equals(token, ARGUMENT_SPACE_SEL_LAST)) {
    selector.sid = space_manager_last_space();
    selector.did_parse = true;
}
```

**Behavior**:
- Returns last space across all displays
- Based on Mission Control ordering

---

#### Recent Space

**Syntax**: `recent`

```bash
yabai -m window --space recent
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:834-838`

```c
if (token_equals(token, ARGUMENT_SPACE_SEL_RECENT)) {
    selector.sid = g_space_manager.last_space_id;
    selector.did_parse = true;
}
```

**Behavior**:
- Returns previously focused space
- Updated on `SPACE_CHANGED` event
- Useful for "move and return" workflows

**Storage**:
```c
struct space_manager {
    uint64_t current_space_id;
    uint64_t last_space_id;  // Recent space
    // ...
};
```

---

### 7.5 Cursor Location

**Syntax**: `mouse`

```bash
yabai -m window --space mouse
```

**Resolution**: `/Users/r/repos/yabai/src/message.c:840-844`

```c
if (token_equals(token, ARGUMENT_SPACE_SEL_MOUSE)) {
    selector.sid = space_manager_cursor_space();
    selector.did_parse = true;
}
```

**Implementation**:
```c
uint64_t space_manager_cursor_space(void)
{
    // 1. Get cursor position
    CGPoint cursor = CGEventGetLocation(CGEventCreate(NULL));

    // 2. Find display containing cursor
    uint32_t did = display_manager_point_display_id(cursor);

    // 3. Get active space on that display
    return display_space_id(did);
}
```

**Use Cases**:
- Multi-monitor setups
- Quick window organization
- Follow-cursor workflows

---

## 8. Related Operations

### 8.1 Move to Display

**Command**: `yabai -m window --display DISPLAY_SEL`

**Implementation**: `/Users/r/repos/yabai/src/message.c:2128-2137`

```c
else if (token_equals(command, COMMAND_WINDOW_DISPLAY)) {
    // Parse display selector (1, 2, next, prev, recent, mouse)
    struct selector selector = parse_display_selector(rsp, &message,
                                                      display_manager_active_display_id(),
                                                      false);

    if (selector.did_parse && selector.did) {
        // Get active space on target display
        uint64_t sid = display_space_id(selector.did);

        if (space_is_fullscreen(sid)) {
            daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
        } else {
            // Use same window_manager_send_window_to_space function
            window_manager_send_window_to_space(&g_space_manager,
                                               &g_window_manager,
                                               acting_window,
                                               sid,
                                               false);
        }
    }
}
```

**Behavior**:
- Resolves display to its active space
- Calls same underlying space move function
- Simpler for multi-monitor workflows

**Examples**:
```bash
# Move to display 2's active space
yabai -m window --display 2

# Move to next display
yabai -m window --display next

# Move to display containing cursor
yabai -m window --display mouse
```

---

### 8.2 Move and Follow

**Not a native command** - Achieved with rule or two commands:

**Option 1: Rule-based** (automatic)
```bash
yabai -m rule --add app="^Safari$" space=2
# Automatically focuses destination space when window moves
```

**Option 2: Two commands** (manual)
```bash
# Move window to space 2
yabai -m window --space 2

# Follow by switching to space 2
yabai -m space --focus 2
```

**Option 3: Shell function**
```bash
yabai_move_and_follow() {
    yabai -m window --space "$1"
    yabai -m space --focus "$1"
}

# Usage
yabai_move_and_follow 2
```

---

### 8.3 Swap Windows Between Spaces

**Command**: `yabai -m window --swap WINDOW_SEL`

**Note**: `--swap` only works within same space. To swap across spaces:

```bash
# Get window IDs
win1=$(yabai -m query -windows --window first | jq '.id')
win2=$(yabai -m query -windows --window last | jq '.id')

# Get their spaces
space1=$(yabai -m query -windows --window $win1 | jq '.space')
space2=$(yabai -m query -windows --window $win2 | jq '.space')

# Swap
yabai -m window $win1 --space $space2
yabai -m window $win2 --space $space1
```

---

### 8.4 Send All Windows to Space

**Not a direct command** - Use query and loop:

```bash
# Get all window IDs on current space
current_space=$(yabai -m query -spaces --space | jq '.index')
window_ids=$(yabai -m query -windows --space $current_space | jq -r '.[].id')

# Move each to target space
for wid in $window_ids; do
    yabai -m window $wid --space 2
done
```

**Or use batch operation** (would require custom implementation):
```c
uint32_t *window_list = space_window_list(src_sid, &count, false);
space_manager_move_window_list_to_space(dst_sid, window_list, count);
```

---

## 9. Query APIs

### 9.1 Get Window's Current Space

**Function**: `window_space()`
**Source**: `/Users/r/repos/yabai/src/window.c:67-87`

```c
uint64_t window_space(uint32_t wid)
{
    uint64_t sid = 0;

    // Create array with single window ID
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);

    // Query spaces for this window
    CFArrayRef space_list_ref = SLSCopySpacesForWindows(g_connection, 0x7, window_list_ref);
    if (!space_list_ref) goto err;

    // Get count (should be 1, or more for sticky windows)
    int count = CFArrayGetCount(space_list_ref);
    if (!count) goto free;

    // Extract first space ID
    CFNumberRef id_ref = CFArrayGetValueAtIndex(space_list_ref, 0);
    CFNumberGetValue(id_ref, CFNumberGetType(id_ref), &sid);

free:
    CFRelease(space_list_ref);
err:
    CFRelease(window_list_ref);

    // Fallback: query window's display space
    return sid ? sid : window_display_space(wid);
}
```

**CLI Equivalent**:
```bash
yabai -m query -windows --window <id> | jq '.space'
```

---

### 9.2 Get All Spaces for Window (Sticky)

**Function**: `window_space_list()`
**Source**: `/Users/r/repos/yabai/src/window.c:89-111`

```c
uint64_t *window_space_list(uint32_t wid, int *count)
{
    *count = 0;

    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    CFArrayRef space_list_ref = SLSCopySpacesForWindows(g_connection, 0x7, window_list_ref);
    if (!space_list_ref) goto err;

    *count = CFArrayGetCount(space_list_ref);
    if (!*count) goto free;

    // Allocate array for space IDs
    uint64_t *space_list = malloc(*count * sizeof(uint64_t));

    // Extract all space IDs
    for (int i = 0; i < *count; ++i) {
        CFNumberRef id_ref = CFArrayGetValueAtIndex(space_list_ref, i);
        CFNumberGetValue(id_ref, CFNumberGetType(id_ref), &space_list[i]);
    }

    CFRelease(space_list_ref);
    CFRelease(window_list_ref);
    return space_list;

free:
    CFRelease(space_list_ref);
err:
    CFRelease(window_list_ref);
    return NULL;
}
```

**Use Case**: Check if window is sticky (visible on all spaces)

```c
int count;
uint64_t *spaces = window_space_list(wid, &count);
if (count > 1) {
    // Window is sticky
}
free(spaces);
```

---

### 9.3 Get Windows on Space

**Function**: `space_window_list()`
**Source**: `/Users/r/repos/yabai/src/space.c:168-231`

```c
uint32_t *space_window_list(uint64_t sid, int *count, bool include_minimized)
{
    *count = 0;

    // Create array with single space ID
    CFArrayRef space_list_ref = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);

    // Query windows on this space
    CFArrayRef window_list_ref = SLSCopyWindowsWithOptionsAndTags(g_connection,
                                                                  0,
                                                                  space_list_ref,
                                                                  0x2,  // Options
                                                                  NULL,
                                                                  NULL);
    CFRelease(space_list_ref);
    if (!window_list_ref) return NULL;

    int window_count = CFArrayGetCount(window_list_ref);
    uint32_t *window_list = malloc(window_count * sizeof(uint32_t));

    // Extract window IDs
    for (int i = 0; i < window_count; ++i) {
        CFNumberRef id_ref = CFArrayGetValueAtIndex(window_list_ref, i);
        CFNumberGetValue(id_ref, CFNumberGetType(id_ref), &window_list[i]);
    }

    CFRelease(window_list_ref);
    *count = window_count;
    return window_list;
}
```

**CLI Equivalent**:
```bash
yabai -m query -windows --space <index>
```

---

### 9.4 Get All Spaces

**Function**: `space_manager_space_list()`

```c
uint64_t *space_manager_space_list(int *count)
{
    // Query all spaces across all displays
    CFArrayRef display_list_ref = SLSCopyManagedDisplaySpaces(g_connection);
    // ... extract space IDs from nested structure ...
    CFRelease(display_list_ref);
    return space_list;
}
```

**CLI Equivalent**:
```bash
yabai -m query -spaces
```

---

### 9.5 Check if Space is Visible

**Function**: `space_is_visible()`
**Source**: `/Users/r/repos/yabai/src/space.c:103-106`

```c
bool space_is_visible(uint64_t sid)
{
    bool result = false;

    // Check if space is currently active on any display
    for (int i = 0; i < g_display_manager.current_display_count; ++i) {
        uint32_t did = g_display_manager.current_display_list[i];
        uint64_t active_sid = display_space_id(did);
        if (active_sid == sid) {
            result = true;
            break;
        }
    }

    return result;
}
```

**Use Case**: Determine if moving window from visible space (affects focus behavior)

---

### 9.6 Validate Move Operation

**Pre-flight Checks**:

```c
bool can_move_window_to_space(struct window *window, uint64_t target_sid)
{
    // Check if space exists
    if (target_sid == 0) {
        return false;
    }

    // Check if fullscreen space
    if (space_is_fullscreen(target_sid)) {
        return false;  // Cannot move to fullscreen space
    }

    // Check if already on target space
    uint64_t current_sid = window_space(window->id);
    if (current_sid == target_sid) {
        return false;  // Already there, no-op
    }

    // All checks passed
    return true;
}
```

---

## 10. Code Examples

### 10.1 Move Focused Window to Next Space

```c
// Get focused window
struct window *window = window_manager_focused_window(&g_window_manager);
if (!window) {
    fprintf(stderr, "No focused window\n");
    return;
}

// Get current space
uint64_t current_sid = window_space(window->id);

// Get next space
uint64_t next_sid = space_manager_next_space(current_sid);
if (!next_sid) {
    fprintf(stderr, "No next space\n");
    return;
}

// Validate not fullscreen
if (space_is_fullscreen(next_sid)) {
    fprintf(stderr, "Cannot move to fullscreen space\n");
    return;
}

// Execute move
window_manager_send_window_to_space(&g_space_manager,
                                   &g_window_manager,
                                   window,
                                   next_sid,
                                   false);
```

---

### 10.2 Move Window to Space by Label

```c
// Find space by label
char *label = "work";
uint64_t target_sid = space_manager_find_space_by_label(&g_space_manager, label);

if (!target_sid) {
    fprintf(stderr, "Space labeled '%s' not found\n", label);
    return;
}

// Get window
struct window *window = window_manager_find_window(&g_window_manager, wid);
if (!window) return;

// Validate
if (space_is_fullscreen(target_sid)) {
    fprintf(stderr, "Cannot move to fullscreen space\n");
    return;
}

uint64_t current_sid = window_space(window->id);
if (current_sid == target_sid) {
    fprintf(stderr, "Window already on target space\n");
    return;
}

// Execute move
window_manager_send_window_to_space(&g_space_manager,
                                   &g_window_manager,
                                   window,
                                   target_sid,
                                   false);
```

---

### 10.3 Move All Windows from One Space to Another

```c
void move_all_windows(uint64_t src_sid, uint64_t dst_sid)
{
    // Validate destination
    if (space_is_fullscreen(dst_sid)) {
        fprintf(stderr, "Cannot move to fullscreen space\n");
        return;
    }

    if (src_sid == dst_sid) {
        fprintf(stderr, "Source and destination are the same\n");
        return;
    }

    // Get window list on source space
    int window_count;
    uint32_t *window_list = space_window_list(src_sid, &window_count, false);

    if (window_count == 0) {
        fprintf(stderr, "No windows on source space\n");
        return;
    }

    // Execute batch move
    space_manager_move_window_list_to_space(dst_sid, window_list, window_count);

    // Note: For full BSP management, would need to call window_manager_send_window_to_space
    // for each window individually. Batch move is lower-level.

    free(window_list);
}
```

---

### 10.4 Move Window and Focus Destination Space

```c
void move_window_and_follow(struct window *window, uint64_t target_sid)
{
    // Validate
    if (space_is_fullscreen(target_sid)) {
        fprintf(stderr, "Cannot move to fullscreen space\n");
        return;
    }

    uint64_t current_sid = window_space(window->id);
    if (current_sid == target_sid) return;

    // Move window
    window_manager_send_window_to_space(&g_space_manager,
                                       &g_window_manager,
                                       window,
                                       target_sid,
                                       false);

    // Switch to destination space
    uint32_t target_did = space_display_id(target_sid);

    if (space_manager_active_space() != target_sid) {
        space_manager_focus_space(target_sid);
    }

    // Re-focus window
    window_manager_focus_window_with_raise(&window->application->psn,
                                          window->id,
                                          window->ref);
}
```

---

### 10.5 Check if Window Can Be Moved

```c
bool validate_window_space_move(uint32_t wid, uint64_t target_sid)
{
    // Check space exists
    if (target_sid == 0) {
        fprintf(stderr, "Invalid space ID\n");
        return false;
    }

    // Check space type
    int space_type = SLSSpaceGetType(g_connection, target_sid);
    if (space_type == 4) {  // Fullscreen
        fprintf(stderr, "Cannot move to fullscreen space\n");
        return false;
    }

    if (space_type == 2) {  // System
        fprintf(stderr, "Warning: Moving to system space\n");
        // Continue anyway
    }

    // Check if already on target space
    uint64_t current_sid = window_space(wid);
    if (current_sid == target_sid) {
        fprintf(stderr, "Window already on target space\n");
        return false;
    }

    // Check if window exists
    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window) {
        fprintf(stderr, "Window not found\n");
        return false;
    }

    return true;
}
```

---

## 11. Swift Implementation Guide

### 11.1 Basic Window Move

```swift
import Foundation

class WindowSpaceMover {
    private let connection: Int32

    init() {
        self.connection = SLSMainConnectionID()
    }

    func moveWindow(_ windowID: UInt32, toSpace spaceID: UInt64) -> Bool {
        // Validate space type
        let spaceType = SLSSpaceGetType(connection, spaceID)
        guard spaceType != 4 else {
            print("Cannot move to fullscreen space")
            return false
        }

        // Check if already on target space
        guard let currentSpace = getWindowSpace(windowID),
              currentSpace != spaceID else {
            print("Window already on target space")
            return false
        }

        // Determine method based on macOS version
        if needsScriptingAddition() {
            return moveViaScriptingAddition(windowID, toSpace: spaceID)
        } else {
            return moveDirectly(windowID, toSpace: spaceID)
        }
    }

    private func moveDirectly(_ windowID: UInt32, toSpace spaceID: UInt64) -> Bool {
        // Create CFArray with window ID
        var wid = windowID
        let windowArray = CFArrayCreate(nil,
                                       [wid] as [UnsafeRawPointer],
                                       1,
                                       nil)
        defer { CFRelease(windowArray) }

        // Execute move
        SLSMoveWindowsToManagedSpace(connection, windowArray, spaceID)
        return true
    }

    private func moveViaScriptingAddition(_ windowID: UInt32, toSpace spaceID: UInt64) -> Bool {
        // Send command to scripting addition via socket
        // Implementation depends on SA socket protocol

        let socketPath = "/tmp/yabai-sa_\(NSUserName()).socket"
        // ... socket communication code ...

        return false  // Placeholder
    }

    private func needsScriptingAddition() -> Bool {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion

        if osVersion.majorVersion == 12 && osVersion.minorVersion >= 7 { return true }
        if osVersion.majorVersion == 13 && osVersion.minorVersion >= 6 { return true }
        if osVersion.majorVersion == 14 && osVersion.minorVersion >= 5 { return true }
        if osVersion.majorVersion >= 15 { return true }

        return false
    }

    func getWindowSpace(_ windowID: UInt32) -> UInt64? {
        var wid = windowID
        let windowArray = CFArrayCreate(nil,
                                       [wid] as [UnsafeRawPointer],
                                       1,
                                       nil)
        defer { CFRelease(windowArray) }

        guard let spaceArray = SLSCopySpacesForWindows(connection, 0x7, windowArray) else {
            return nil
        }
        defer { CFRelease(spaceArray) }

        guard CFArrayGetCount(spaceArray) > 0 else { return nil }

        guard let spaceNumber = CFArrayGetValueAtIndex(spaceArray, 0) as? NSNumber else {
            return nil
        }

        return spaceNumber.uint64Value
    }
}

// Private API declarations
@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ windowList: CFArray, _ spaceID: UInt64)

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ selector: Int32, _ windowList: CFArray) -> CFArray?

@_silgen_name("SLSSpaceGetType")
func SLSSpaceGetType(_ cid: Int32, _ spaceID: UInt64) -> Int32
```

---

### 11.2 Batch Window Move

```swift
extension WindowSpaceMover {
    func moveWindows(_ windowIDs: [UInt32], toSpace spaceID: UInt64) -> Bool {
        guard !windowIDs.isEmpty else { return false }

        // Validate space
        let spaceType = SLSSpaceGetType(connection, spaceID)
        guard spaceType != 4 else {
            print("Cannot move to fullscreen space")
            return false
        }

        if needsScriptingAddition() {
            return batchMoveViaScriptingAddition(windowIDs, toSpace: spaceID)
        } else {
            return batchMoveDirectly(windowIDs, toSpace: spaceID)
        }
    }

    private func batchMoveDirectly(_ windowIDs: [UInt32], toSpace spaceID: UInt64) -> Bool {
        // Create CFArray with multiple window IDs
        let windowArray = CFArrayCreate(nil,
                                       windowIDs.map { $0 as CFTypeRef },
                                       windowIDs.count,
                                       nil)
        defer { CFRelease(windowArray) }

        // Execute batch move
        SLSMoveWindowsToManagedSpace(connection, windowArray, spaceID)
        return true
    }

    private func batchMoveViaScriptingAddition(_ windowIDs: [UInt32], toSpace spaceID: UInt64) -> Bool {
        // Send batch command to SA
        // Opcode: 0x12 (SA_OPCODE_WINDOW_LIST_TO_SPACE)

        // ... SA communication ...

        return false  // Placeholder
    }
}
```

---

### 11.3 Space Queries

```swift
class SpaceManager {
    private let connection: Int32

    init() {
        self.connection = SLSMainConnectionID()
    }

    func getAllSpaces() -> [UInt64] {
        guard let displaySpaces = SLSCopyManagedDisplaySpaces(connection) else {
            return []
        }
        defer { CFRelease(displaySpaces) }

        var spaceIDs: [UInt64] = []

        // Parse nested structure
        // displaySpaces is array of dictionaries
        // Each dict has "Spaces" key with array of space info

        guard let displays = displaySpaces as? [[String: Any]] else { return [] }

        for display in displays {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    if let spaceID = space["id64"] as? UInt64 {
                        spaceIDs.append(spaceID)
                    }
                }
            }
        }

        return spaceIDs
    }

    func getWindowsOnSpace(_ spaceID: UInt64) -> [UInt32] {
        // Create CFArray with space ID
        let spaceArray = CFArrayCreate(nil,
                                      [spaceID as CFTypeRef],
                                      1,
                                      nil)
        defer { CFRelease(spaceArray) }

        // Query windows
        guard let windowArray = SLSCopyWindowsWithOptionsAndTags(connection,
                                                                 0,
                                                                 spaceArray,
                                                                 0x2,
                                                                 nil,
                                                                 nil) else {
            return []
        }
        defer { CFRelease(windowArray) }

        // Extract window IDs
        let count = CFArrayGetCount(windowArray)
        var windowIDs: [UInt32] = []

        for i in 0..<count {
            if let windowID = CFArrayGetValueAtIndex(windowArray, i) as? NSNumber {
                windowIDs.append(windowID.uint32Value)
            }
        }

        return windowIDs
    }

    func isSpaceFullscreen(_ spaceID: UInt64) -> Bool {
        return SLSSpaceGetType(connection, spaceID) == 4
    }

    func isSpaceUser(_ spaceID: UInt64) -> Bool {
        return SLSSpaceGetType(connection, spaceID) == 0
    }
}

// Additional private API declarations
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
func SLSCopyWindowsWithOptionsAndTags(
    _ cid: Int32,
    _ owner: UInt32,
    _ spaces: CFArray,
    _ options: UInt32,
    _ setTags: UnsafeMutablePointer<UInt64>?,
    _ clearTags: UnsafeMutablePointer<UInt64>?
) -> CFArray?
```

---

### 11.4 Complete Example: Move and Follow

```swift
class WindowManager {
    private let spaceMover = WindowSpaceMover()
    private let spaceManager = SpaceManager()

    func moveWindowAndFollow(windowID: UInt32, toSpace targetSpaceID: UInt64) {
        // Get current space
        guard let currentSpace = spaceMover.getWindowSpace(windowID) else {
            print("Could not determine window's current space")
            return
        }

        // Validate target
        guard !spaceManager.isSpaceFullscreen(targetSpaceID) else {
            print("Cannot move to fullscreen space")
            return
        }

        guard currentSpace != targetSpaceID else {
            print("Window already on target space")
            return
        }

        // Execute move
        guard spaceMover.moveWindow(windowID, toSpace: targetSpaceID) else {
            print("Failed to move window")
            return
        }

        // Switch to destination space
        focusSpace(targetSpaceID)

        // Small delay for space transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Re-focus window (would need AX API)
            // AXUIElementPerformAction(windowRef, kAXRaiseAction)
        }
    }

    private func focusSpace(_ spaceID: UInt64) {
        // This requires scripting addition or CGSSetWorkspace
        // Simplified placeholder
        print("Switching to space \(spaceID)")
    }
}
```

---

## 12. File Reference Map

### Command Parsing

| File | Line | Description |
|------|------|-------------|
| `src/message.c` | 135 | `COMMAND_WINDOW_SPACE` definition |
| `src/message.c` | 2138-2146 | `--space` command handler |
| `src/message.c` | 2128-2137 | `--display` command handler |
| `src/message.c` | 789-868 | Space selector parsing |

### Core Implementation

| File | Line | Description |
|------|------|-------------|
| `src/window_manager.h` | 187 | Function declaration |
| `src/window_manager.c` | 2080-2109 | `send_window_to_space()` implementation |
| `src/space_manager.h` | 91-92 | Space move declarations |
| `src/space_manager.c` | 658-682 | Space move implementations |

### Private APIs

| File | Line | Description |
|------|------|-------------|
| `src/misc/extern.h` | 61 | `SLSMoveWindowsToManagedSpace` |
| `src/misc/extern.h` | 21 | `SLSCopySpacesForWindows` |
| `src/misc/extern.h` | 22 | `SLSCopyWindowsWithOptionsAndTags` |
| `src/misc/extern.h` | 54 | `SLSSpaceGetType` |
| `src/misc/extern.h` | 94-95 | Compatibility workspace APIs |

### Scripting Addition

| File | Line | Description |
|------|------|-------------|
| `src/sa.h` | 28-29 | Client function declarations |
| `src/sa.m` | 605-622 | Client implementations |
| `src/osax/common.h` | 22-43 | Opcode definitions |
| `src/osax/payload.m` | 907-931 | Payload handlers (batch) |
| `src/osax/payload.m` | 920-931 | Single window move handler |

### Query Functions

| File | Line | Description |
|------|------|-------------|
| `src/window.h` | 138-139 | Window space query declarations |
| `src/window.c` | 67-111 | Window space implementations |
| `src/space.c` | 88-106 | Space type checking |
| `src/space.c` | 168-231 | Space window list |
| `src/workspace.m` | 17-26 | Version detection |

### Space Management

| File | Line | Description |
|------|------|-------------|
| `src/space_manager.h` | Various | Space query declarations |
| `src/space_manager.c` | Various | Space navigation functions |
| `src/display.c` | Various | Display-space relationships |

---

## Summary

**yabai provides comprehensive window-to-space movement capabilities:**

✅ **Supports**: Moving windows between any user spaces
✅ **Methods**: Direct SkyLight API, scripting addition, compatibility mode
✅ **Selectors**: Index, label, relative, cursor-based
✅ **Operations**: Single, batch, cross-display
✅ **Management**: Automatic untiling, re-tiling, focus handling

❌ **Limitations**: Cannot move to fullscreen spaces

**Requirements**:
- Accessibility permissions (always)
- Scripting addition (macOS 12.7+, 13.6+, 14.5+, 15.0+)
- SIP filesystem protections disabled (for SA)

**This specification provides complete reference for implementing window-to-space movement in any programming language or framework.**

---

**End of Specification**
