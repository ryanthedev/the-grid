# macOS Private API Specification
## Window and Space Management APIs

**Version:** 1.0
**Based on:** yabai window manager implementation
**Target platforms:** macOS 11.0+ (Big Sur through Tahoe 26.0+)
**Architectures:** Intel x86_64, Apple Silicon ARM64

---

## Table of Contents

1. [Introduction](#introduction)
2. [Prerequisites & Security](#prerequisites--security)
3. [SkyLight Framework (SLS*)](#skylight-framework-sls)
4. [Core Graphics Services (CGS*)](#core-graphics-services-cgs)
5. [Accessibility API Extensions](#accessibility-api-extensions)
6. [Process Services (_SLPS*)](#process-services-_slps)
7. [CoreDock Private APIs](#coredock-private-apis)
8. [Scripting Addition (OSAX)](#scripting-addition-osax)
9. [Version Compatibility Matrix](#version-compatibility-matrix)
10. [Privilege Level Summary](#privilege-level-summary)
11. [Implementation Patterns](#implementation-patterns)
12. [Alternatives & Fallbacks](#alternatives--fallbacks)

---

## Introduction

This document provides a comprehensive reference to macOS private APIs used for window and space (virtual desktop) management. These APIs are not part of the official macOS SDK and are subject to change between OS versions.

The primary framework is **SkyLight.framework** (`/System/Library/PrivateFrameworks/SkyLight.framework`), which provides the window server interface. Additional private APIs come from Core Graphics Services, Process Services, and CoreDock.

**Key capabilities enabled by these APIs:**
- Window server connection and management
- Window queries, manipulation, and ordering
- Space (virtual desktop) creation, destruction, and switching
- Display management and multi-monitor support
- Window-to-space assignment
- Advanced window properties (opacity, transforms, layers)
- Mission Control integration

---

## Prerequisites & Security

### Required Permissions

**Minimum (Read-only operations):**
- Accessibility API access (`AXIsProcessTrusted`)

**Full functionality (Write operations):**
- Accessibility API access
- System Integrity Protection (SIP) partially disabled:
  - `csrutil enable --without fs --without debug`
  - Requires: `CSR_ALLOW_UNRESTRICTED_FS` (0x02) and `CSR_ALLOW_TASK_FOR_PID` (0x04)
- Scripting Addition loaded into Dock.app

### Privilege Levels

APIs in this document are marked with privilege requirements:

| Symbol | Meaning | Requirements |
|--------|---------|--------------|
| 🟢 | **Public** | No special privileges |
| 🟡 | **Accessibility** | Requires accessibility permission |
| 🔴 | **Scripting Addition** | Requires SIP disabled + SA loaded |

---

## SkyLight Framework (SLS*)

The SkyLight framework (`SkyLight.framework`) is the primary interface to the macOS window server. All functions are declared in `SkyLight/SkyLight.h` (private header).

### Connection Management

#### SLSMainConnectionID
**Signature:**
```c
int SLSMainConnectionID(void)
```

**Purpose:** Get the main connection ID to the window server for the current process.

**Returns:**
- `int` - Connection ID (typically > 0)

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- This is the primary connection used for most window server operations
- Should be called once and cached
- Returns the same value for all threads in a process

**Error Codes:** None (always succeeds)

---

#### SLSNewConnection
**Signature:**
```c
CGError SLSNewConnection(int zero, int *cid)
```

**Purpose:** Create a new connection to the window server (used for parallel operations like animations).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `zero` | `int` | Reserved, always pass `0` |
| `cid` | `int*` | Output parameter for new connection ID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success, error code otherwise

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Used for creating separate connections for animations to avoid blocking main operations
- Each connection has its own event queue and state
- Must be released with `SLSReleaseConnection` when done

**Error Codes:**
- `0` - Success
- Non-zero - Connection creation failed

**Alternatives:** Use main connection for simple operations

---

#### SLSReleaseConnection
**Signature:**
```c
CGError SLSReleaseConnection(int cid)
```

**Purpose:** Release a window server connection created with `SLSNewConnection`.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID to release |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Do not release the main connection from `SLSMainConnectionID`
- Releasing a connection invalidates all pending operations on it

**Error Codes:**
- `0` - Success
- Non-zero - Invalid connection ID

---

#### SLSRegisterConnectionNotifyProc
**Signature:**
```c
typedef void (*connection_callback)(int, int, void*);
CGError SLSRegisterConnectionNotifyProc(int cid,
                                        connection_callback *handler,
                                        uint32_t event,
                                        void *context)
```

**Purpose:** Register a callback for window server events.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `handler` | `connection_callback*` | Callback function pointer |
| `event` | `uint32_t` | Event type to monitor |
| `context` | `void*` | User data passed to callback |

**Event Types:**
| Code | Event | Description |
|------|-------|-------------|
| `808` | Window Ordered | Window z-order changed |
| `804` | Window Destroyed | Window was destroyed |
| `1204` | Mission Control Enter | Entered Mission Control |
| `1205` | Mission Control Exit | Exited Mission Control |
| `1327` | Space Created | New space created |
| `1328` | Space Destroyed | Space was destroyed |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Callback is invoked on the connection's event loop thread
- Multiple callbacks can be registered for different events
- Some events may not fire reliably on all macOS versions

**Error Codes:**
- `0` - Success
- Non-zero - Registration failed

---

### Window Queries & Properties

#### SLSGetWindowBounds
**Signature:**
```c
CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame)
```

**Purpose:** Get the frame (position and size) of a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `frame` | `CGRect*` | Output parameter for window frame |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Returns frame in screen coordinates (origin at top-left)
- More reliable than AX API for some windows
- May return cached values; use with window server synchronization

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1001` - Window destroyed

**Alternatives:** Use AX API `kAXPositionAttribute` and `kAXSizeAttribute` (slower but works without private APIs)

---

#### SLSGetWindowLevel
**Signature:**
```c
CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level)
```

**Purpose:** Get the window level (z-order layer).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `level` | `int*` | Output parameter for window level |

**Window Levels:**
| Value | Constant | Description |
|-------|----------|-------------|
| `0` | `kCGNormalWindowLevel` | Normal windows |
| `-1` | Below normal | Windows below normal |
| `3` | `kCGFloatingWindowLevel` | Floating windows |
| `5` | `kCGModalPanelWindowLevel` | Modal dialogs |
| `24` | `kCGPopUpMenuWindowLevel` | Popup menus |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Window level determines layering relative to other windows
- Windows at higher levels appear above those at lower levels

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID

---

#### SLSGetWindowSubLevel
**Signature:**
```c
int SLSGetWindowSubLevel(int cid, uint32_t wid)
```

**Purpose:** Get the window sub-level within its level (fine-grained z-order).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |

**Returns:**
- `int` - Sub-level value (higher = above)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Sub-levels provide ordering within the same window level
- Used for precise window stacking control

---

#### SLSGetWindowAlpha
**Signature:**
```c
CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha)
```

**Purpose:** Get the alpha (opacity) value of a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `alpha` | `float*` | Output parameter (0.0 = transparent, 1.0 = opaque) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Returns system-level alpha, not application-level alpha
- May return 1.0 even if window appears transparent (app-level transparency)

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID

---

#### SLSGetWindowOwner
**Signature:**
```c
CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid)
```

**Purpose:** Get the connection ID of the window's owner (owning process).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `wcid` | `int*` | Output parameter for owner's connection ID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Use `SLSConnectionGetPID` to convert connection ID to PID
- Useful for tracking window ownership across processes

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID

---

#### SLSWindowIsOrderedIn
**Signature:**
```c
CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *value)
```

**Purpose:** Check if a window is currently visible (ordered into the window server).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `value` | `uint8_t*` | Output parameter (0 = not visible, 1 = visible) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Minimized windows return 0
- Windows on inactive spaces may return 0 or 1 depending on macOS version

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID

**Alternatives:** Check window's `kAXMinimizedAttribute` via AX API

---

#### SLSCopyWindowProperty
**Signature:**
```c
CGError SLSCopyWindowProperty(int cid,
                               uint32_t wid,
                               CFStringRef property,
                               CFTypeRef *value)
```

**Purpose:** Get a window property (like title, role, etc.).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `property` | `CFStringRef` | Property key |
| `value` | `CFTypeRef*` | Output parameter (caller must release) |

**Common Properties:**
| Key | Type | Description |
|-----|------|-------------|
| `kCGSWindowTitle` | `CFStringRef` | Window title |
| `kCGSWindowBounds` | `CFDictionaryRef` | Window frame |
| `kCGSWindowLevel` | `CFNumberRef` | Window level |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Returned value must be released with `CFRelease`
- Not all properties are available for all windows
- Property keys are not publicly documented

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1002` - Property not available

**Alternatives:** Use AX API attributes (more reliable and documented)

---

#### SLSCopyAssociatedWindows
**Signature:**
```c
CFArrayRef SLSCopyAssociatedWindows(int cid, uint32_t wid)
```

**Purpose:** Get windows associated with a parent window (children, sheets, etc.).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Parent window ID |

**Returns:**
- `CFArrayRef` - Array of window IDs (`CFNumberRef`), or `NULL` if none. Caller must release.

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Includes sheets, popovers, and child windows
- Array may be empty even if window has children visible via AX API
- Useful for window hierarchy tracking

**Alternatives:** Use AX API to query child windows via `kAXChildrenAttribute`

---

### Window Manipulation (Requires Scripting Addition)

#### SLSSetWindowAlpha
**Signature:**
```c
CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha)
```

**Purpose:** Set the system-level alpha (opacity) of a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `alpha` | `float` | Alpha value (0.0 = transparent, 1.0 = opaque) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.0+

**Implementation Notes:**
- Requires SA when setting alpha on windows not owned by calling process
- May cause visual glitches on some window types
- Use transactions for smooth animated transitions

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied (no SA)

**Alternatives:** None for system-level transparency; app must implement its own alpha

---

#### SLSMoveWindow
**Signature:**
```c
CGError SLSMoveWindow(int cid, uint32_t wid, CGPoint *point)
```

**Purpose:** Move a window to a specific position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `point` | `CGPoint*` | New position (screen coordinates, top-left origin) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.0+

**Implementation Notes:**
- For windows with groups/shadows, use `SLSMoveWindowWithGroup` instead
- Position is in global screen coordinates
- May not work for fullscreen windows

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

**Alternatives:** Use AX API `kAXPositionAttribute` (works without SA for most windows)

---

#### SLSMoveWindowWithGroup
**Signature:**
```c
OSStatus SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point)
```

**Purpose:** Move a window and its associated windows (group) to a position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `point` | `CGPoint*` | New position |

**Returns:**
- `OSStatus` - `noErr` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Moves window along with shadows, tooltips, and associated windows
- Preferred over `SLSMoveWindow` for most use cases
- Maintains relative positions of grouped windows

**Error Codes:**
- `0` - Success
- Non-zero - Move failed

---

#### SLSOrderWindow
**Signature:**
```c
CGError SLSOrderWindow(int cid, uint32_t wid, int mode, uint32_t rel_wid)
```

**Purpose:** Order a window relative to another window (z-order control).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID to order |
| `mode` | `int` | Ordering mode |
| `rel_wid` | `uint32_t` | Reference window ID (or 0) |

**Ordering Modes:**
| Value | Constant | Description |
|-------|----------|-------------|
| `1` | Above | Order above reference window |
| `-1` | Below | Order below reference window |
| `0` | Out | Order out (hide/unmap) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.0+

**Implementation Notes:**
- Windows must be at the same window level to order relative to each other
- `rel_wid = 0` means relative to all windows at that level
- Does not raise/focus the window

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

**Alternatives:** Use `AXUIElementPerformAction` with `kAXRaiseAction` (limited)

---

#### SLSSetWindowLevel
**Signature:**
```c
CGError SLSSetWindowLevel(int cid, uint32_t wid, int level)
```

**Purpose:** Set the window level (layer) of a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `level` | `int` | New window level |

**Common Levels:**
| Value | Description |
|-------|-------------|
| `0` | Normal window level |
| `-1` | Below normal |
| `3` | Floating |
| `5` | Modal panel |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.0+

**Implementation Notes:**
- Changing level affects window ordering relative to other windows
- Some levels are reserved for system windows
- May cause unexpected behavior with fullscreen windows

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

**Alternatives:** None; window level control requires private APIs

---

#### SLSSetWindowSubLevel
**Signature:**
```c
CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sub_level)
```

**Purpose:** Set the window sub-level (fine-grained z-order within a level).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `sub_level` | `int` | New sub-level (higher = above) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Sub-level only affects ordering within the same window level
- Useful for precise window stacking

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

---

#### SLSSetWindowTags
**Signature:**
```c
CGError SLSSetWindowTags(int cid,
                         uint32_t wid,
                         uint64_t *tags,
                         int tag_size)
```

**Purpose:** Set window tags (bitfield flags for window attributes).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `tags` | `uint64_t*` | Pointer to tags array |
| `tag_size` | `int` | Size of tags array (typically 64) |

**Common Tags:**
| Bit | Hex | Description |
|-----|-----|-------------|
| `3` | `0x8` | Disable shadow |
| `11` | `0x800` | Sticky (visible on all spaces) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Tags is a 64-element array where each element can be 0 or 1
- Setting a tag bit to 1 enables that attribute
- Most tag meanings are undocumented

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

**Alternatives:** For sticky windows, use `SLSProcessAssignToAllSpaces` on the process instead

---

#### SLSClearWindowTags
**Signature:**
```c
CGError SLSClearWindowTags(int cid,
                           uint32_t wid,
                           uint64_t *tags,
                           int tag_size)
```

**Purpose:** Clear window tags (remove attributes).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `tags` | `uint64_t*` | Pointer to tags array to clear |
| `tag_size` | `int` | Size of tags array |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Use to remove sticky behavior or re-enable shadows
- Clears only the bits set to 1 in the tags array

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

---

#### SLSSetWindowTransform
**Signature:**
```c
CGError SLSSetWindowTransform(int cid,
                               uint32_t wid,
                               CGAffineTransform t)
```

**Purpose:** Apply an affine transformation to a window (scale, rotate, translate).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `t` | `CGAffineTransform` | Transformation matrix |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Used for picture-in-picture mode and window scaling
- Identity transform `CGAffineTransformIdentity` resets the window
- Transformed windows may have input/interaction issues
- Transform is visual only; AX API still reports original frame

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied

**Alternatives:** None; window transformations require private APIs

---

#### SLSGetWindowTransform
**Signature:**
```c
CGError SLSGetWindowTransform(int cid,
                               uint32_t wid,
                               CGAffineTransform *t)
```

**Purpose:** Get the current affine transformation of a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `t` | `CGAffineTransform*` | Output parameter for transformation |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns identity transform if window is not transformed
- Use to check if window has been scaled/transformed

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID

---

### Window Creation & Destruction

#### SLSNewWindowWithOpaqueShapeAndContext
**Signature:**
```c
CGError SLSNewWindowWithOpaqueShapeAndContext(int cid,
                                               int type,
                                               CFTypeRef region,
                                               CFTypeRef opaque_shape,
                                               int options,
                                               uint64_t *tags,
                                               float x,
                                               float y,
                                               int tag_size,
                                               uint32_t *wid,
                                               void *context)
```

**Purpose:** Create a new window with specific shape and properties.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `type` | `int` | Window type (2 = normal) |
| `region` | `CFTypeRef` | Window region (from `CGSNewRegionWithRect`) |
| `opaque_shape` | `CFTypeRef` | Opaque region (or `NULL`) |
| `options` | `int` | Window options (0 for default) |
| `tags` | `uint64_t*` | Initial tags array |
| `x` | `float` | Initial x position |
| `y` | `float` | Initial y position |
| `tag_size` | `int` | Size of tags array |
| `wid` | `uint32_t*` | Output parameter for window ID |
| `context` | `void*` | Graphics context (or `NULL`) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Used for creating overlay windows (feedback, borders, etc.)
- Created windows have no chrome (borderless)
- Must manually manage window lifecycle

**Error Codes:**
- `0` - Success
- Non-zero - Window creation failed

---

#### SLSReleaseWindow
**Signature:**
```c
CGError SLSReleaseWindow(int cid, uint32_t wid)
```

**Purpose:** Destroy/release a window created with `SLSNewWindow*`.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID to release |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Only for windows created by your process
- Window is immediately destroyed
- Do not use on application windows

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID
- `1004` - Permission denied (not owner)

---

#### SLSSetWindowShape
**Signature:**
```c
CGError SLSSetWindowShape(int cid,
                           uint32_t wid,
                           float x_offset,
                           float y_offset,
                           CFTypeRef shape)
```

**Purpose:** Set the shape/region of a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |
| `x_offset` | `float` | X offset for shape |
| `y_offset` | `float` | Y offset for shape |
| `shape` | `CFTypeRef` | Region object |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Used to update window regions dynamically
- Primarily for windows created by your process

**Error Codes:**
- `0` - Success
- `1000` - Invalid window ID

---

### Window Iterator/Query System

#### SLSWindowQueryWindows
**Signature:**
```c
CFTypeRef SLSWindowQueryWindows(int cid,
                                CFArrayRef windows,
                                int count)
```

**Purpose:** Create a query object for retrieving window information.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `windows` | `CFArrayRef` | Array of window IDs (or `NULL` for all) |
| `count` | `int` | Number of windows (or window list limit) |

**Returns:**
- `CFTypeRef` - Query object (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Use with `SLSWindowQueryResultCopyWindows` to get iterator
- Efficient for bulk window queries
- Release query with `CFRelease`

---

#### SLSWindowQueryResultCopyWindows
**Signature:**
```c
CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef window_query)
```

**Purpose:** Get an iterator from a window query result.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `window_query` | `CFTypeRef` | Query object from `SLSWindowQueryWindows` |

**Returns:**
- `CFTypeRef` - Iterator object (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

---

#### SLSWindowIteratorAdvance
**Signature:**
```c
bool SLSWindowIteratorAdvance(CFTypeRef iterator)
```

**Purpose:** Advance to the next window in an iterator.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `iterator` | `CFTypeRef` | Iterator object |

**Returns:**
- `bool` - `true` if advanced to next window, `false` if no more windows

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

---

#### SLSWindowIteratorGetWindowID
**Signature:**
```c
uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator)
```

**Purpose:** Get the window ID at the current iterator position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `iterator` | `CFTypeRef` | Iterator object |

**Returns:**
- `uint32_t` - Window ID

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

---

#### SLSWindowIteratorGetLevel
**Signature:**
```c
int SLSWindowIteratorGetLevel(CFTypeRef iterator)
```

**Purpose:** Get the window level at the current iterator position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `iterator` | `CFTypeRef` | Iterator object |

**Returns:**
- `int` - Window level

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

---

### Display Management

#### SLSCopyManagedDisplays
**Signature:**
```c
CFArrayRef SLSCopyManagedDisplays(int cid)
```

**Purpose:** Get an array of all managed display UUIDs.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |

**Returns:**
- `CFArrayRef` - Array of `CFStringRef` display UUIDs (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns UUIDs, not display IDs
- Use `CGDisplayCreateUUIDFromDisplayID` to convert display ID to UUID
- Array is ordered but order is not guaranteed stable

---

#### SLSCopyManagedDisplayForWindow
**Signature:**
```c
CFStringRef SLSCopyManagedDisplayForWindow(int cid, uint32_t wid)
```

**Purpose:** Get the UUID of the display containing a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `wid` | `uint32_t` | Window ID |

**Returns:**
- `CFStringRef` - Display UUID (must be released), or `NULL` if window not visible

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns display with most window area
- May return `NULL` for minimized or hidden windows

**Error Codes:**
- `NULL` - Window not found or not visible

**Alternatives:** Use `CGMainDisplayID()` or calculate from window frame

---

#### SLSCopyBestManagedDisplayForRect
**Signature:**
```c
CFStringRef SLSCopyBestManagedDisplayForRect(int cid, CGRect rect)
```

**Purpose:** Get the UUID of the display best matching a rectangle.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `rect` | `CGRect` | Rectangle in screen coordinates |

**Returns:**
- `CFStringRef` - Display UUID (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns display with most overlap with rectangle
- Useful for positioning windows on specific displays

---

#### SLSManagedDisplayIsAnimating
**Signature:**
```c
bool SLSManagedDisplayIsAnimating(int cid, CFStringRef uuid)
```

**Purpose:** Check if a display is currently animating (during space switch).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `uuid` | `CFStringRef` | Display UUID |

**Returns:**
- `bool` - `true` if animating, `false` otherwise

**Privilege:** 🟢 Public

**Version:** macOS 10.7+

**Implementation Notes:**
- Used to avoid operations during space transition animations
- Returns `true` during Mission Control and space switching

**Alternatives:** Track NSWorkspace notifications for space changes

---

#### SLSSetActiveMenuBarDisplayIdentifier
**Signature:**
```c
CGError SLSSetActiveMenuBarDisplayIdentifier(int cid,
                                              CFStringRef uuid,
                                              CFStringRef repeat_uuid)
```

**Purpose:** Set which display has the active menu bar (focus display).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `uuid` | `CFStringRef` | Display UUID to activate |
| `repeat_uuid` | `CFStringRef` | Same as `uuid` (appears redundant) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.9+

**Implementation Notes:**
- Changes which display is considered "active"
- May cause menu bar to move if "Displays have separate Spaces" is disabled
- Both UUID parameters appear to need the same value

**Error Codes:**
- `0` - Success
- Non-zero - Invalid display UUID

**Alternatives:** Synthesize mouse movement to target display

---

### Menu Bar & Dock

#### SLSSetMenuBarInsetAndAlpha
**Signature:**
```c
CGError SLSSetMenuBarInsetAndAlpha(int cid,
                                    double unused1,
                                    double unused2,
                                    float alpha)
```

**Purpose:** Set the menu bar transparency.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `unused1` | `double` | Reserved (pass 0) |
| `unused2` | `double` | Reserved (pass 0) |
| `alpha` | `float` | Alpha value (0.0 = transparent, 1.0 = opaque) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.10+

**Implementation Notes:**
- Affects global menu bar transparency
- Changes persist until logout or override
- May not work on all macOS versions/configurations

**Error Codes:**
- `0` - Success

**Alternatives:** None; menu bar transparency requires private APIs

---

#### SLSGetDockRectWithReason
**Signature:**
```c
CGError SLSGetDockRectWithReason(int cid, CGRect *rect, int *reason)
```

**Purpose:** Get the Dock's current frame and state.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `rect` | `CGRect*` | Output parameter for Dock frame |
| `reason` | `int*` | Output parameter for Dock state |

**Reason Values:**
| Value | Description |
|-------|-------------|
| `0` | Dock hidden |
| `1` | Dock visible |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Used to calculate usable display area
- Rect includes Dock area even when auto-hidden
- Combine with CoreDock APIs for full Dock state

**Error Codes:**
- `0` - Success

---

### Space/Desktop Management (Core Functionality)

#### SLSCopyManagedDisplaySpaces
**Signature:**
```c
CFArrayRef SLSCopyManagedDisplaySpaces(int cid)
```

**Purpose:** Get all spaces across all displays with metadata.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |

**Returns:**
- `CFArrayRef` - Array of dictionaries containing space information (must be released)

**Dictionary Keys:**
| Key | Type | Description |
|-----|------|-------------|
| `"Spaces"` | `CFArrayRef` | Array of space dictionaries |
| `"Display Identifier"` | `CFStringRef` | Display UUID |
| `"Current Space"` | `CFDictionaryRef` | Current space info |

**Space Dictionary Keys:**
| Key | Type | Description |
|-----|------|-------------|
| `"ManagedSpaceID"` | `CFNumberRef` | Space ID (uint64_t) |
| `"id64"` | `CFNumberRef` | Space ID (alternative key) |
| `"uuid"` | `CFStringRef` | Space UUID |
| `"type"` | `CFNumberRef` | Space type (0=user, 4=fullscreen) |

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- This is the primary API for space enumeration
- Space IDs are `uint64_t` values
- Used extensively for space navigation and management
- Structure changed slightly in macOS 13+

**Error Codes:**
- `NULL` - Failed to get spaces

**Alternatives:** None; space enumeration requires private APIs

---

#### SLSManagedDisplayGetCurrentSpace
**Signature:**
```c
uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref)
```

**Purpose:** Get the active space ID for a specific display.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `display_ref` | `CFStringRef` | Display UUID |

**Returns:**
- `uint64_t` - Current space ID for the display

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns 0 if display not found
- Each display has its own current space
- Use with "Displays have separate Spaces" enabled

**Error Codes:**
- `0` - Display not found or invalid UUID

---

#### SLSManagedDisplaySetCurrentSpace
**Signature:**
```c
void SLSManagedDisplaySetCurrentSpace(int cid,
                                      CFStringRef display_ref,
                                      uint64_t sid)
```

**Purpose:** Set the active space for a display (switch spaces).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `display_ref` | `CFStringRef` | Display UUID |
| `sid` | `uint64_t` | Space ID to activate |

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Must be used with `SLSShowSpaces` and `SLSHideSpaces` for proper space switching
- Call order: `SLSShowSpaces(new_space)` → `SLSHideSpaces(old_space)` → `SLSManagedDisplaySetCurrentSpace`
- Does not animate; animations handled separately
- Requires SA to switch spaces on external displays

**Error Codes:** None (void return)

**Alternatives:** Use Mission Control APIs via CoreDock or AppleScript (limited)

---

#### SLSShowSpaces
**Signature:**
```c
void SLSShowSpaces(int cid, CFArrayRef space_list)
```

**Purpose:** Show (make visible) one or more spaces.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `space_list` | `CFArrayRef` | Array of space IDs (`CFNumberRef` of `uint64_t`) |

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Part of the space switching sequence
- Must be called before `SLSManagedDisplaySetCurrentSpace`
- Makes spaces visible to the window server
- Does not focus the space; use `SLSManagedDisplaySetCurrentSpace` for that

**Error Codes:** None (void return)

**Alternatives:** None; space visibility requires private APIs

---

#### SLSHideSpaces
**Signature:**
```c
void SLSHideSpaces(int cid, CFArrayRef space_list)
```

**Purpose:** Hide (make invisible) one or more spaces.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `space_list` | `CFArrayRef` | Array of space IDs (`CFNumberRef` of `uint64_t`) |

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Part of the space switching sequence
- Called after `SLSManagedDisplaySetCurrentSpace` to hide old space
- Hiding a space removes it from the visible window list

**Error Codes:** None (void return)

---

#### SLSCopyManagedDisplayForSpace
**Signature:**
```c
CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid)
```

**Purpose:** Get the UUID of the display containing a space.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `sid` | `uint64_t` | Space ID |

**Returns:**
- `CFStringRef` - Display UUID (must be released), or `NULL` if space not found

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Each space belongs to exactly one display
- Returns `NULL` for invalid or destroyed spaces

**Error Codes:**
- `NULL` - Space not found

---

#### SLSSpaceGetType
**Signature:**
```c
int SLSSpaceGetType(int cid, uint64_t sid)
```

**Purpose:** Get the type of a space.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `sid` | `uint64_t` | Space ID |

**Space Types:**
| Value | Description |
|-------|-------------|
| `0` | User space (normal desktop) |
| `2` | System space (login window, etc.) |
| `4` | Fullscreen space |

**Returns:**
- `int` - Space type

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Fullscreen apps create type 4 spaces
- System spaces should generally be ignored
- Type can change if app enters/exits fullscreen

**Error Codes:**
- `-1` or undefined - Space not found

---

#### SLSSpaceCopyName
**Signature:**
```c
CFStringRef SLSSpaceCopyName(int cid, uint64_t sid)
```

**Purpose:** Get the UUID/name of a space.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `sid` | `uint64_t` | Space ID |

**Returns:**
- `CFStringRef` - Space UUID string (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns UUID, not user-visible name
- UUIDs persist across reboots in some macOS versions
- Useful for tracking spaces across sessions

**Error Codes:**
- `NULL` - Space not found

---

#### SLSCopySpacesForWindows
**Signature:**
```c
CFArrayRef SLSCopySpacesForWindows(int cid,
                                   int selector,
                                   CFArrayRef window_list)
```

**Purpose:** Get the spaces containing specific windows.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `selector` | `int` | Space selector (0x7 = all spaces) |
| `window_list` | `CFArrayRef` | Array of window IDs (`CFNumberRef`) |

**Selector Values:**
| Value | Description |
|-------|-------------|
| `0x7` | All spaces |
| `0x5` | Visible spaces |

**Returns:**
- `CFArrayRef` - Array of arrays; outer array index matches window_list, inner arrays contain space IDs (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Returns array of space ID arrays
- Windows can be on multiple spaces (sticky windows)
- Empty inner array means window not on any space (minimized/hidden)

**Error Codes:**
- `NULL` - Query failed

---

#### SLSCopyWindowsWithOptionsAndTags
**Signature:**
```c
CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid,
                                            uint32_t owner,
                                            CFArrayRef spaces,
                                            uint32_t options,
                                            uint64_t *set_tags,
                                            uint64_t *clear_tags)
```

**Purpose:** Get windows on specific spaces with filtering options.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `owner` | `uint32_t` | Owner connection ID (0 = all) |
| `spaces` | `CFArrayRef` | Array of space IDs, or `NULL` for all |
| `options` | `uint32_t` | Filter options |
| `set_tags` | `uint64_t*` | Required tags (NULL = ignore) |
| `clear_tags` | `uint64_t*` | Excluded tags (NULL = ignore) |

**Options:**
| Value | Description |
|-------|-------------|
| `0x2` | On-screen windows only |
| `0x7` | Include minimized windows |

**Returns:**
- `CFArrayRef` - Array of window IDs (`CFNumberRef`) (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Primary method for getting windows on a space
- Options control visibility filtering
- Tag filtering allows finding sticky windows, etc.

**Error Codes:**
- `NULL` - Query failed

---

#### SLSMoveWindowsToManagedSpace
**Signature:**
```c
void SLSMoveWindowsToManagedSpace(int cid,
                                  CFArrayRef window_list,
                                  uint64_t sid)
```

**Purpose:** Move windows to a specific space.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `window_list` | `CFArrayRef` | Array of window IDs (`CFNumberRef`) |
| `sid` | `uint64_t` | Target space ID |

**Privilege:** 🟢 Public (but see notes)

**Version:** macOS 10.5+

**Implementation Notes:**
- Works without SA on macOS < 12.7
- On macOS >= 12.7, requires workaround using `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace`
- Does not focus the windows or switch spaces
- May silently fail for fullscreen windows

**Error Codes:** None (void return)

**Alternatives:** Use `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` on macOS 12.7+

---

#### SLSSpaceSetCompatID
**Signature:**
```c
CGError SLSSpaceSetCompatID(int cid, uint64_t sid, int workspace)
```

**Purpose:** Set a compatibility workspace ID for a space (used for window movement workaround).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `sid` | `uint64_t` | Space ID |
| `workspace` | `int` | Workspace number (1-based) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Required workaround for moving windows on macOS >= 12.7
- Set compat ID for target space, then use `SLSSetWindowListWorkspace`
- Temporary setting; does not persist

**Error Codes:**
- `0` - Success
- Non-zero - Invalid space ID

---

#### SLSSetWindowListWorkspace
**Signature:**
```c
CGError SLSSetWindowListWorkspace(int cid,
                                   uint32_t *window_list,
                                   int window_count,
                                   int workspace)
```

**Purpose:** Move windows to a workspace by compatibility ID.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `window_list` | `uint32_t*` | Array of window IDs |
| `window_count` | `int` | Number of windows |
| `workspace` | `int` | Workspace number (from `SLSSpaceSetCompatID`) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Use with `SLSSpaceSetCompatID` for macOS 12.7+ window movement
- Workspace is 1-based index
- Alternative to `SLSMoveWindowsToManagedSpace`

**Error Codes:**
- `0` - Success
- Non-zero - Invalid workspace or windows

---

#### SLSReassociateWindowsSpacesByGeometry
**Signature:**
```c
CGError SLSReassociateWindowsSpacesByGeometry(int cid,
                                               CFArrayRef window_list)
```

**Purpose:** Update window-to-space associations based on window geometry.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `window_list` | `CFArrayRef` | Array of window IDs (`CFNumberRef`) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🔴 Scripting Addition

**Version:** macOS 10.5+

**Implementation Notes:**
- Called after moving windows with `SLSMoveWindowWithGroup`
- Updates which space owns the window based on its position
- Required for proper space tracking after manual window moves

**Error Codes:**
- `0` - Success
- Non-zero - Update failed

---

### Process Management

#### SLSProcessAssignToSpace
**Signature:**
```c
CGError SLSProcessAssignToSpace(int cid, pid_t pid, uint64_t sid)
```

**Purpose:** Assign a process to a specific space (pin to space).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `pid` | `pid_t` | Process ID |
| `sid` | `uint64_t` | Space ID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Process and its windows only appear on specified space
- Overrides "assign to all spaces" setting
- Process must be running

**Error Codes:**
- `0` - Success
- Non-zero - Invalid PID or space ID

**Alternatives:** None; process-space assignment requires private APIs

---

#### SLSProcessAssignToAllSpaces
**Signature:**
```c
CGError SLSProcessAssignToAllSpaces(int cid, pid_t pid)
```

**Purpose:** Make a process visible on all spaces (sticky).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `pid` | `pid_t` | Process ID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Process and its windows appear on all spaces
- Alternative to per-window sticky tags
- Persists until changed or process exits

**Error Codes:**
- `0` - Success
- Non-zero - Invalid PID

---

#### SLSConnectionGetPID
**Signature:**
```c
CGError SLSConnectionGetPID(int cid, pid_t *pid)
```

**Purpose:** Get the process ID for a connection ID.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `pid` | `pid_t*` | Output parameter for PID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Used to convert window owner connection ID to PID
- Essential for process tracking

**Error Codes:**
- `0` - Success
- Non-zero - Invalid connection ID

---

### Transactions (Batched Operations)

#### SLSTransactionCreate
**Signature:**
```c
CFTypeRef SLSTransactionCreate(int cid)
```

**Purpose:** Create a transaction for batching window server operations atomically.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |

**Returns:**
- `CFTypeRef` - Transaction object (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Use for smooth animations and atomic updates
- All operations in transaction applied simultaneously
- Must commit with `SLSTransactionCommit`

---

#### SLSTransactionCommit
**Signature:**
```c
CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous)
```

**Purpose:** Commit a transaction and apply all batched operations.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `transaction` | `CFTypeRef` | Transaction object |
| `synchronous` | `int` | 1 = synchronous, 0 = asynchronous |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Synchronous mode blocks until complete
- Asynchronous mode returns immediately
- Transaction object is invalid after commit

**Error Codes:**
- `0` - Success
- Non-zero - Commit failed

---

#### SLSTransactionSetWindowTransform
**Signature:**
```c
CGError SLSTransactionSetWindowTransform(CFTypeRef transaction,
                                         uint32_t wid,
                                         int unknown,
                                         int unknown2,
                                         CGAffineTransform t)
```

**Purpose:** Set window transform within a transaction (for animations).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `transaction` | `CFTypeRef` | Transaction object |
| `wid` | `uint32_t` | Window ID |
| `unknown` | `int` | Reserved (pass 0) |
| `unknown2` | `int` | Reserved (pass 0) |
| `t` | `CGAffineTransform` | Transformation matrix |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Used for smooth window animations
- Transform applied when transaction commits
- Combine with alpha changes for fade effects

**Error Codes:**
- `0` - Success
- Non-zero - Invalid window or transaction

---

#### SLSTransactionSetWindowAlpha
**Signature:**
```c
CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction,
                                     uint32_t wid,
                                     float alpha)
```

**Purpose:** Set window alpha within a transaction.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `transaction` | `CFTypeRef` | Transaction object |
| `wid` | `uint32_t` | Window ID |
| `alpha` | `float` | Alpha value (0.0-1.0) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- For smooth opacity animations
- Applied atomically on commit

**Error Codes:**
- `0` - Success
- Non-zero - Invalid window or transaction

---

### Miscellaneous

#### SLSDisableUpdate
**Signature:**
```c
CGError SLSDisableUpdate(int cid)
```

**Purpose:** Temporarily disable screen updates for batched visual changes.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Use before making multiple visual changes
- Must re-enable with `SLSReenableUpdate`
- Avoid holding disabled for long periods (causes UI freeze)

**Error Codes:**
- `0` - Success

---

#### SLSReenableUpdate
**Signature:**
```c
CGError SLSReenableUpdate(int cid)
```

**Purpose:** Re-enable screen updates after `SLSDisableUpdate`.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Always call after `SLSDisableUpdate`
- Flushes pending visual changes
- Screen updates resume immediately

**Error Codes:**
- `0` - Success

---

#### SLSHWCaptureWindowList
**Signature:**
```c
CFArrayRef SLSHWCaptureWindowList(int cid,
                                  uint32_t *window_list,
                                  int window_count,
                                  uint32_t options)
```

**Purpose:** Hardware-accelerated window capture (screenshot).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `window_list` | `uint32_t*` | Array of window IDs |
| `window_count` | `int` | Number of windows |
| `options` | `uint32_t` | Capture options |

**Common Options:**
| Value | Description |
|-------|-------------|
| `(1 << 11) \| (1 << 8)` | Standard capture with compositing |

**Returns:**
- `CFArrayRef` - Array of capture dictionaries containing `CGImage` data (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Used for creating window proxies/snapshots
- Requires Screen Recording permission on macOS 10.15+
- Returns images in array matching input window order

**Error Codes:**
- `NULL` - Capture failed or permission denied

**Alternatives:** Use `CGWindowListCreateImage` (public API, requires Screen Recording permission)

---

#### SLSGetCurrentCursorLocation
**Signature:**
```c
CGError SLSGetCurrentCursorLocation(int cid, CGPoint *point)
```

**Purpose:** Get the current cursor position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |
| `point` | `CGPoint*` | Output parameter for cursor position |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Returns position in global screen coordinates
- Updates on each call (not cached)

**Error Codes:**
- `0` - Success

**Alternatives:** Use `CGEventGetLocation(CGEventCreate(NULL))` (public API)

---

## Core Graphics Services (CGS*)

Core Graphics Services provides low-level graphics and window server extensions.

### CGSGetConnectionPortById
**Signature:**
```c
mach_port_t CGSGetConnectionPortById(int cid)
```

**Purpose:** Get the Mach port for a connection ID (for low-level IPC).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `cid` | `int` | Connection ID |

**Returns:**
- `mach_port_t` - Mach port for connection

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Function pointer resolved dynamically via `dlsym`
- Used for low-level window server communication
- Required for some advanced operations

**Alternatives:** None; Mach port access requires private APIs

---

### CGSNewRegionWithRect
**Signature:**
```c
CGError CGSNewRegionWithRect(CGRect *rect, CFTypeRef *region)
```

**Purpose:** Create a region object from a rectangle.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `rect` | `CGRect*` | Rectangle |
| `region` | `CFTypeRef*` | Output parameter for region (must be released) |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Used for window shapes and clipping regions
- Region must be released with `CFRelease`

**Error Codes:**
- `0` - Success
- Non-zero - Region creation failed

---

### CGRegionCreateEmptyRegion
**Signature:**
```c
CFTypeRef CGRegionCreateEmptyRegion(void)
```

**Purpose:** Create an empty region.

**Returns:**
- `CFTypeRef` - Empty region object (must be released)

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- Used for window creation
- Combine with other region functions to build complex shapes

---

## Accessibility API Extensions

### _AXUIElementGetWindow
**Signature:**
```c
AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid)
```

**Purpose:** Get the window ID from an Accessibility UI element.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `ref` | `AXUIElementRef` | AX UI element reference |
| `wid` | `uint32_t*` | Output parameter for window ID |

**Returns:**
- `AXError` - `kAXErrorSuccess` (0) on success

**Privilege:** 🟡 Accessibility

**Version:** macOS 10.4+

**Implementation Notes:**
- Bridges AX API to window IDs
- Essential for correlating AX elements with SLS windows
- Defined in `HIServices/AXUIElement.h` (private)

**Error Codes:**
- `0` - Success
- `kAXErrorInvalidUIElement` - Element is not a window
- `kAXErrorAPIDisabled` - Accessibility not enabled

**Alternatives:** None; AX-to-window-ID mapping requires private APIs

---

### _AXUIElementCreateWithRemoteToken
**Signature:**
```c
AXUIElementRef _AXUIElementCreateWithRemoteToken(CFDataRef data)
```

**Purpose:** Create an AX UI element from a remote token (for cross-process references).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `data` | `CFDataRef` | Remote token data |

**Returns:**
- `AXUIElementRef` - AX UI element reference (must be released), or `NULL` on failure

**Privilege:** 🟡 Accessibility

**Version:** macOS 10.10+

**Implementation Notes:**
- Used for remote window references
- Token is obtained from window server
- Enables cross-process AX element access

**Error Codes:**
- `NULL` - Invalid token

---

## Process Services (_SLPS*)

Process Services handles process management and focus.

### _SLPSGetFrontProcess
**Signature:**
```c
OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn)
```

**Purpose:** Get the frontmost (focused) process.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `psn` | `ProcessSerialNumber*` | Output parameter for process serial number |

**Returns:**
- `OSStatus` - `noErr` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- ProcessSerialNumber is deprecated but still functional
- Returns currently focused application
- Use for focus tracking

**Error Codes:**
- `0` - Success
- Non-zero - Failed to get front process

**Alternatives:** Use `NSWorkspace.sharedWorkspace.frontmostApplication` (public API)

---

### _SLPSSetFrontProcessWithOptions
**Signature:**
```c
CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn,
                                        uint32_t wid,
                                        uint32_t mode)
```

**Purpose:** Set the frontmost process and optionally focus a window.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `psn` | `ProcessSerialNumber*` | Process serial number |
| `wid` | `uint32_t` | Window ID (or 0 for none) |
| `mode` | `uint32_t` | Focus mode |

**Focus Modes:**
| Value | Constant | Description |
|-------|----------|-------------|
| `0x100` | `kCPSAllWindows` | Focus all windows |
| `0x200` | `kCPSUserGenerated` | User-initiated focus |
| `0x400` | `kCPSNoWindows` | Focus app only, no windows |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.0+

**Implementation Notes:**
- More reliable than AX API for focusing
- `kCPSUserGenerated` recommended for most uses
- Combine with window ID for precise focus control

**Error Codes:**
- `0` - Success
- Non-zero - Focus failed

**Alternatives:** Use `NSRunningApplication.activateWithOptions:` (public API, limited options)

---

## CoreDock Private APIs

CoreDock framework provides Dock integration.

### CoreDockGetAutoHideEnabled
**Signature:**
```c
Boolean CoreDockGetAutoHideEnabled(void)
```

**Purpose:** Check if Dock auto-hide is enabled.

**Returns:**
- `Boolean` - `true` if auto-hide enabled, `false` otherwise

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Use for calculating usable display area
- Combine with `SLSGetDockRectWithReason`

**Alternatives:** None; Dock state requires private APIs

---

### CoreDockGetOrientationAndPinning
**Signature:**
```c
void CoreDockGetOrientationAndPinning(int *orientation, int *pinning)
```

**Purpose:** Get Dock position and pinning state.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `orientation` | `int*` | Output for orientation |
| `pinning` | `int*` | Output for pinning |

**Orientation Values:**
| Value | Description |
|-------|-------------|
| `1` | Bottom |
| `2` | Left |
| `3` | Right |

**Pinning Values:**
| Value | Description |
|-------|-------------|
| `0` | Not pinned (center) |
| `1` | Pinned to start |
| `2` | Pinned to end |

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Essential for display bounds calculations
- Pinning affects Dock position within edge

**Alternatives:** None

---

### CoreDockSendNotification
**Signature:**
```c
CGError CoreDockSendNotification(CFStringRef notification, int unknown)
```

**Purpose:** Send notification to Dock.app (trigger Mission Control, etc.).

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `notification` | `CFStringRef` | Notification name |
| `unknown` | `int` | Reserved (pass 0) |

**Notifications:**
| Name | Description |
|------|-------------|
| `"com.apple.expose.awake"` | Show Mission Control |
| `"com.apple.expose.front.awake"` | Show application windows |
| `"com.apple.showdesktop.awake"` | Show desktop |

**Returns:**
- `CGError` - `kCGErrorSuccess` (0) on success

**Privilege:** 🟢 Public

**Version:** macOS 10.5+

**Implementation Notes:**
- Triggers Mission Control animations
- Does not wait for completion
- Some notifications may not work on all macOS versions

**Error Codes:**
- `0` - Success
- Non-zero - Notification failed

**Alternatives:** AppleScript (`tell application "System Events" to key code 160`) - unreliable

---

## Scripting Addition (OSAX)

The Scripting Addition is a code injection mechanism that loads into Dock.app to access private Objective-C methods and patch memory.

### Overview

**Installation Path:** `/Library/ScriptingAdditions/yabai.osax/`

**Injection Target:** Dock.app

**Requirements:**
- SIP partially disabled (`csrutil enable --without fs --without debug`)
- `CSR_ALLOW_UNRESTRICTED_FS` (0x02) and `CSR_ALLOW_TASK_FOR_PID` (0x04) flags enabled

### Dock.app Private Classes

#### Dock.spaces / ManagedSpace
**Class:** `Dock` with category `spaces` (or `ManagedSpace` on macOS 15+)

**Methods:**
```objc
+ (id)spacesForDisplay:(NSString *)displayUUID;
+ (NSString *)displayIDForSpace:(uint64_t)spaceID;
+ (uint64_t)currentSpaceForDisplayUUID:(NSString *)uuid;  // Pre-Sequoia
+ (uint64_t)currentSpaceforDisplayUUID:(NSString *)uuid;  // Sequoia+ (typo in API)
```

**Purpose:** Access space metadata and state

**Privilege:** 🔴 Scripting Addition

**Implementation Notes:**
- Method name typo (`forDisplayUUID`) exists in macOS 15+
- Must be called from within Dock.app context
- Returns internal Dock space representations

---

#### DPDesktopPictureManager
**Class:** `DPDesktopPictureManager`

**Methods:**
```objc
- (void)moveSpace:(id)space toDisplay:(uint32_t)displayID displayUUID:(NSString *)uuid;
```

**Purpose:** Move space to different display

**Privilege:** 🔴 Scripting Addition

**Implementation Notes:**
- `space` parameter is internal Dock space object
- Allows moving spaces between displays programmatically

---

### Private Functions (Located via Pattern Matching)

The SA uses hex pattern matching to locate functions in Dock.app's binary. Patterns are macOS version and architecture-specific.

#### addSpace Function
**Signature:** Unknown (called via inline assembly)

**Purpose:** Create new space beyond 16-space limit

**Privilege:** 🔴 Scripting Addition

**Version Specific:** macOS 11.0 - 26.0+

**Implementation Notes:**
- Located via hex pattern matching in Dock binary
- Offsets stored per macOS version
- Bypasses Mission Control's 16-space limit
- Invoked via inline assembly with custom register setup

**Patterns:** Stored in `src/osax/arm64_payload.m` and `src/osax/x64_payload.m`

---

#### removeSpace Function
**Signature:** Unknown (called via inline assembly)

**Purpose:** Destroy space

**Privilege:** 🔴 Scripting Addition

**Version Specific:** macOS 11.0 - 26.0+

**Implementation Notes:**
- Located via hex pattern matching
- Allows removing spaces programmatically
- Must not remove last remaining space

---

#### moveSpace Function
**Signature:** Unknown (called via inline assembly)

**Purpose:** Reorder spaces (change index)

**Privilege:** 🔴 Scripting Addition

**Version Specific:** macOS 11.0 - 26.0+

**Implementation Notes:**
- Located via hex pattern matching
- Changes space ordering in Mission Control
- Used for space swapping operations

---

#### setFrontWindow Function
**Signature:** Unknown (called via inline assembly)

**Purpose:** Focus window (alternative to AX API)

**Privilege:** 🔴 Scripting Addition

**Version Specific:** macOS 11.0 - 26.0+

**Implementation Notes:**
- Located via hex pattern matching
- More reliable than AX API for some windows
- Direct window server operation

---

#### Animation Time Patching
**Memory Address:** Located via pattern matching

**Purpose:** Disable or modify Dock space-switching animations

**Privilege:** 🔴 Scripting Addition

**Version Specific:** macOS 11.0 - 26.0+

**Implementation Notes:**
- Memory address contains animation duration value
- Patched using `vm_protect` to make writable
- **x86_64:** Set to `0x660fefc0660fefc0` (near-zero float)
- **ARM64:** Set to `0x2f00e400` (near-zero float)
- Significantly speeds up space switching

**Technique:**
1. Locate animation time variable via hex pattern
2. Use `mach_vm_protect` to make memory writable
3. Write near-zero value
4. Restore memory protection

---

### OSAX Communication Protocol

**IPC Method:** Unix domain socket (`/tmp/yabai-sa_<user>.socket`)

**Message Format:** Binary protocol with opcodes

**Opcodes:** (from `src/osax/common.h`)

| Opcode | Name | Description |
|--------|------|-------------|
| `0x01` | `SA_OPCODE_HANDSHAKE` | Verify SA connection |
| `0x02` | `SA_OPCODE_SPACE_FOCUS` | Focus space |
| `0x03` | `SA_OPCODE_SPACE_CREATE` | Create space |
| `0x04` | `SA_OPCODE_SPACE_DESTROY` | Destroy space |
| `0x05` | `SA_OPCODE_SPACE_MOVE` | Move/reorder space |
| `0x06` | `SA_OPCODE_WINDOW_MOVE` | Move window |
| `0x07` | `SA_OPCODE_WINDOW_OPACITY` | Set window opacity |
| `0x08` | `SA_OPCODE_WINDOW_OPACITY_FADE` | Animated opacity |
| `0x09` | `SA_OPCODE_WINDOW_LAYER` | Set window level |
| `0x0A` | `SA_OPCODE_WINDOW_STICKY` | Set sticky flag |
| `0x0B` | `SA_OPCODE_WINDOW_SHADOW` | Set shadow state |
| `0x0C` | `SA_OPCODE_WINDOW_FOCUS` | Focus window |
| `0x0D` | `SA_OPCODE_WINDOW_SCALE` | Transform window |
| `0x0E` | `SA_OPCODE_WINDOW_SWAP_PROXY_IN` | Swap proxy in |
| `0x0F` | `SA_OPCODE_WINDOW_SWAP_PROXY_OUT` | Swap proxy out |
| `0x10` | `SA_OPCODE_WINDOW_ORDER` | Order window |
| `0x11` | `SA_OPCODE_WINDOW_ORDER_IN` | Order window in |
| `0x12` | `SA_OPCODE_WINDOW_LIST_TO_SPACE` | Move windows to space |
| `0x13` | `SA_OPCODE_WINDOW_TO_SPACE` | Move window to space |

**Attributes:** (capability flags)

| Flag | Description |
|------|-------------|
| `OSAX_ATTRIB_DOCK_SPACES` (0x01) | Space enumeration |
| `OSAX_ATTRIB_DPPM` (0x02) | Desktop picture manager |
| `OSAX_ATTRIB_ADD_SPACE` (0x04) | Create space |
| `OSAX_ATTRIB_REM_SPACE` (0x08) | Remove space |
| `OSAX_ATTRIB_MOV_SPACE` (0x10) | Move space |
| `OSAX_ATTRIB_SET_WINDOW` (0x20) | Window operations |
| `OSAX_ATTRIB_ANIM_TIME` (0x40) | Animation control |

---

## Version Compatibility Matrix

| API Function | 11.x | 12.x | 13.x | 14.x | 15.x | 26.x | Notes |
|--------------|------|------|------|------|------|------|-------|
| **SkyLight Connection** ||||||
| `SLSMainConnectionID` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `SLSNewConnection` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `SLSRegisterConnectionNotifyProc` | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | Event codes changed in 13+ |
| **Window Queries** ||||||
| `SLSGetWindowBounds` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `SLSGetWindowLevel` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `SLSCopyWindowProperty` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| **Window Manipulation** ||||||
| `SLSSetWindowAlpha` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Requires SA |
| `SLSMoveWindowWithGroup` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Requires SA |
| `SLSSetWindowTransform` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Requires SA |
| **Space Management** ||||||
| `SLSCopyManagedDisplaySpaces` | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | Dict structure changed in 13+ |
| `SLSShowSpaces` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Requires SA |
| `SLSHideSpaces` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Requires SA |
| `SLSMoveWindowsToManagedSpace` | ✅ | ⚠️ | ❌ | ❌ | ❌ | ❌ | Broken in 12.7+, use workaround |
| `SLSSpaceSetCompatID` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Workaround for 12.7+ |
| **OSAX Functions** ||||||
| `addSpace` pattern | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | New pattern for 26.1 ARM64 |
| `removeSpace` pattern | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `animation_time_addr` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | |
| **Dock Classes** ||||||
| `Dock.spaces` | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | Renamed to ManagedSpace in 15+ |
| `ManagedSpace` | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | Replaces Dock.spaces |

**Legend:**
- ✅ Fully supported
- ⚠️ Works with modifications/workarounds
- ❌ Not supported/broken

---

## Privilege Level Summary

### Public (No Special Privileges)
- All SLS query functions (window bounds, level, properties)
- Display management
- Space enumeration (`SLSCopyManagedDisplaySpaces`)
- Window iterator system
- Transactions (read operations)
- CoreDock queries

### Accessibility Permission Required
- AX API extensions (`_AXUIElementGetWindow`)
- Standard AX operations on windows

### Scripting Addition Required
- Window manipulation (opacity, transform, layer, sticky)
- Window ordering and movement
- Space switching (`SLSShowSpaces`, `SLSHideSpaces`, `SLSManagedDisplaySetCurrentSpace`)
- Space creation/destruction (via Dock.app private functions)
- Window animations with proxies
- Animation time patching

---

## Implementation Patterns

### Space Switching Pattern
```
1. Get current and target space IDs
2. Check display is not animating (SLSManagedDisplayIsAnimating)
3. Create space ID arrays for show/hide
4. SLSShowSpaces([target_space])
5. SLSHideSpaces([current_space])
6. SLSManagedDisplaySetCurrentSpace(display, target_space)
7. Optional: Trigger animation via CoreDockSendNotification
```

**Version Notes:**
- Must use SA for external displays
- Built-in display can sometimes switch without SA on newer macOS
- Always call in this order to avoid race conditions

---

### Window Movement to Space (macOS 12.7+)
```
1. Get space index (1-based) for target space
2. SLSSpaceSetCompatID(cid, target_sid, space_index)
3. SLSSetWindowListWorkspace(cid, window_ids, count, space_index)
```

**Version Notes:**
- Required workaround because `SLSMoveWindowsToManagedSpace` broken in 12.7+
- Compat ID is temporary and non-persistent
- Use old `SLSMoveWindowsToManagedSpace` on macOS < 12.7

---

### Smooth Window Animation
```
1. transaction = SLSTransactionCreate(cid)
2. SLSTransactionSetWindowTransform(transaction, wid, 0, 0, start_transform)
3. SLSTransactionSetWindowAlpha(transaction, wid, start_alpha)
4. SLSTransactionCommit(transaction, 0)  // Apply start state
5. CFRelease(transaction)

6. transaction = SLSTransactionCreate(cid)
7. SLSTransactionSetWindowTransform(transaction, wid, 0, 0, end_transform)
8. SLSTransactionSetWindowAlpha(transaction, wid, end_alpha)
9. SLSTransactionCommit(transaction, 1)  // Synchronous commit animates
10. CFRelease(transaction)
```

**Implementation Notes:**
- Two transactions: one for start state, one for end state
- Synchronous commit on second transaction enables animation
- Window server interpolates between states
- Animation duration controlled by system settings or SA patching

---

### Window Focus Pattern
```
1. Get window's PSN (ProcessSerialNumber)
2. _SLPSSetFrontProcessWithOptions(&psn, window_id, kCPSUserGenerated)
3. Optional: AXUIElementSetAttributeValue(window_ref, kAXMainAttribute, kCFBooleanTrue)
```

**Implementation Notes:**
- `_SLPSSetFrontProcessWithOptions` more reliable than pure AX
- Use `kCPSUserGenerated` (0x200) for user-initiated focus
- AX API as fallback for stubborn windows

---

### Space Creation (Requires SA)
```
1. Load SA into Dock.app
2. Send SA_OPCODE_SPACE_CREATE via socket
3. SA locates addSpace function via pattern matching
4. SA calls addSpace via inline assembly
5. New space ID returned
6. Update space enumeration cache
```

**Implementation Notes:**
- Pattern matching required because function signature is unknown
- Patterns stored per macOS version and architecture
- May fail if Dock.app binary structure changes

---

### Disabling Animations (Requires SA)
```
1. Load SA into Dock.app
2. Locate animation_time_addr via pattern matching
3. vm_protect(task, addr, size, FALSE, VM_PROT_READ | VM_PROT_WRITE)
4. Write near-zero float value:
   - x86_64: 0x660fefc0660fefc0
   - ARM64: 0x2f00e400
5. vm_protect(task, addr, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE)
```

**Implementation Notes:**
- Patches Dock.app memory directly
- Requires task_for_pid capability (SIP disabled)
- Effect lasts until Dock restart
- Speeds up space switching dramatically

---

## Alternatives & Fallbacks

### When SA is Not Available

**Space Switching:**
- ❌ Cannot switch spaces programmatically
- Alternative: Use AppleScript with Mission Control key codes (unreliable)
- Alternative: Synthesize keyboard shortcuts (Ctrl+Left/Right)

**Space Creation/Destruction:**
- ❌ No alternative; limited to existing spaces
- Workaround: Pre-create 16 spaces manually

**Window Movement Between Spaces:**
- ✅ `SLSMoveWindowsToManagedSpace` (macOS < 12.7)
- ✅ `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` (macOS 12.7+)
- Both work without SA

**Window Opacity:**
- ❌ No system-level transparency control
- Alternative: App must implement its own opacity

**Window Transform:**
- ❌ No alternative; requires SA

**Window Focus:**
- ✅ Use `_SLPSSetFrontProcessWithOptions` (works without SA)
- ✅ Use AX API `kAXMainAttribute` (works without SA)

---

### When Accessibility Permission Denied

**Window Queries:**
- ✅ Use SLS APIs (`SLSGetWindowBounds`, etc.)
- These work without accessibility permission

**Window Manipulation:**
- ❌ Cannot set window attributes via AX
- May still work via SLS if SA available

---

### macOS Version-Specific Workarounds

**macOS 12.7+ Window Movement:**
- Old: `SLSMoveWindowsToManagedSpace` ❌
- New: `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` ✅

**macOS 13+ Space Enumeration:**
- Dictionary structure changed
- Keys remain compatible but nesting different
- Check for `"id64"` if `"ManagedSpaceID"` not found

**macOS 15+ OSAX:**
- `Dock.spaces` → `ManagedSpace` class rename
- Method names changed (`currentSpaceforDisplayUUID` typo)
- Update pattern matching for new binary layout

---

## Error Handling Best Practices

### SLS Function Returns
Most SLS functions return `CGError`:
- `0` (`kCGErrorSuccess`) - Success
- `1000` - Invalid window/space ID
- `1001` - Object destroyed
- `1004` - Permission denied
- Other values - Consult `CGError.h` (private)

**Pattern:**
```c
CGError err = SLSGetWindowBounds(cid, wid, &frame);
if (err != kCGErrorSuccess) {
    // Handle error: window may be destroyed or invalid
}
```

### Void Return Functions
Functions like `SLSShowSpaces`, `SLSHideSpaces` return void:
- No error indication
- Verify state change via query functions
- Check for animations completing

**Pattern:**
```c
SLSShowSpaces(cid, space_array);
// Wait and verify
usleep(50000);  // 50ms
uint64_t current = SLSManagedDisplayGetCurrentSpace(cid, display_uuid);
```

### NULL Return Checks
Functions returning CoreFoundation types:
- Always check for `NULL`
- Release with `CFRelease` when done

**Pattern:**
```c
CFArrayRef displays = SLSCopyManagedDisplays(cid);
if (displays) {
    // Use displays
    CFRelease(displays);
}
```

### OSAX Communication
Socket communication can fail:
- Check socket connection success
- Verify handshake response
- Timeout on operations (don't block indefinitely)

---

## Conclusion

This specification documents 100+ private macOS APIs used for advanced window and space management. These APIs provide capabilities not available through public macOS frameworks, but come with significant caveats:

**Risks:**
- APIs can change or break between macOS versions
- Requires SIP disabled for full functionality
- No official documentation or support
- Potential security implications

**Benefits:**
- Comprehensive window server control
- Space management beyond Mission Control limits
- Advanced window manipulation (opacity, transforms)
- Programmatic display and focus management

**Recommended Approach:**
1. Use public APIs (AX, NSWorkspace) wherever possible
2. Fall back to SLS query functions for read operations
3. Use SA only when necessary for write operations
4. Implement version detection and graceful degradation
5. Test thoroughly on all supported macOS versions

For implementation examples, refer to the yabai source code in `/Users/r/repos/yabai/src/`.

---

**Document Version:** 1.0
**Last Updated:** 2025
**Based on:** yabai v7.1.16+ (commit e33e94c)
