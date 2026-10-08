# Finding: SkyLight space moves are silently ignored on macOS 26.2

For the repo owner. Found while building `window.pull` / `space.switch`
(2026-09-20, macOS 26.2 build 25C56, SIP "Custom Configuration", two displays
with separate spaces).

## Summary

From an unprivileged process, the window server on this machine **ignores every
SkyLight call that moves a window to a space that is not visible**. The calls
return normally; the window stays where it was. Reads (displays, spaces, types,
windows per space, spaces of a window) all work and are exact.

The existing `WindowManipulator.moveWindowToSpace` is affected, and so is the
`updateWindow` RPC: **`updateWindow` with a `spaceId` answers
`{"success":true,"updatesApplied":["space"]}` while doing nothing.**

## What was tried

One test window of my own (a TextEdit document on the lower display's current
user space 3), target: the same display's other user space 4 (hidden, empty).
After each attempt the window's spaces were read back with
`SLSCopySpacesForWindows` for over a second, with the run loop turning.

| Attempt | Returned | Window afterwards |
|---|---|---|
| Server: `updateWindow {windowId, spaceId:"4"}` → `moveWindowToSpace` → `SLSMoveWindowsToManagedSpace` | `success: true` | still on 3 (`warn.move.sls_unverified`, expected 4, actual 3) |
| Harness: `SLSMoveWindowsToManagedSpace(cid, [wid], 4)` | void | still on 3 |
| Harness: compat-ID workaround (`SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace`) | non-zero codes | still on 3 |
| Harness: `SLSAddWindowsToSpaces` + `SLSRemoveWindowsFromSpaces` | void | still on 3 |
| Harness: `SLSSpaceAddWindowsAndRemoveFromSpaces(cid, 4, [wid], 7)` | non-zero | still on 3 |

All the symbols resolve (`dlsym`), including `SLSManagedDisplaySetCurrentSpace`,
`SLSShowSpaces`, `SLSHideSpaces`, `SLSProcessAssignToSpace`. Present is not the
same as honored.

## Log evidence

`sls.move.confirmed` / `warn.move.sls_unverified` across the retained server logs:

- **19 confirmed**, every one to space 3 or space 6 — the two displays' visible
  user spaces at the time, i.e. cross-display moves, where the grid also sets the
  window's frame onto the other display.
- **57 unverified**: 28 × (3 → 6), 28 × (6 → 3), and the 1 × (3 → 4) above.

So even between visible spaces the SkyLight move alone is confirmed only a quarter
of the time, and a move to a hidden space has never been confirmed. What actually
carries a window across displays is most likely the frame change, not this call.

## Consequences

- `window.pull` (hidden space → current space) will most likely fail on this OS.
  It reads the result back and says "was not pulled" rather than claiming success.
  Its happy path has **not** been exercised live: there was no way to put a test
  window on a hidden space without switching spaces.
- `space.switch` uses `SLSManagedDisplaySetCurrentSpace` and has **not been called
  live at all**. Given the above it may well be ignored too. It reads the display's
  current space back and fails if it did not change; only after the record flips
  does it call `SLSShowSpaces` / `SLSHideSpaces`, so an ignored call leaves nothing
  half-done.
- `updateWindow`'s `spaceId` and `moveWindowToDisplay`'s space step report success
  they cannot know. Suggest returning the read-back verdict, as `window.pull` does.

## Candidate fallback (untested)

Synthesize the Mission Control shortcut (ctrl+← / ctrl+→, or ctrl+digit if the
user has enabled "Switch to Desktop N") through the existing HID path: it is the
OS's own switch, so the Dock stays consistent. Open questions that need a live
test on a machine that is not showing anything precious:

1. Which display it acts on — the one under the pointer, or the one with keyboard
   focus. This is why it was not chosen now: a wrong guess switches the *other*
   display, and here that display was playing a fullscreen video.
2. Whether the shortcuts are enabled (`com.apple.symbolichotkeys`, ids 79/81 and
   118+), read-only.
3. Relative stepping: reaching space N means pressing |Δindex| times and waiting
   out each animation; verify with `SLSManagedDisplayGetCurrentSpace` after each,
   and check that no *other* display's current space changed.

For pulling a window rather than going to it, the only unprivileged route known is
holding the window's title bar with a synthesized mouse-down while switching
spaces, which needs the same live testing and a space switch each way. The
scripting-addition route (as yabai uses) needs SIP partially disabled and was
already removed from this codebase.
