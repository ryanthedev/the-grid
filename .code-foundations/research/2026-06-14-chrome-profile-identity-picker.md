# Research: Chrome Profile Identity per Window in the Picker

**One-liner:** Make theGrid's picker label each Chrome window with its real profile (e.g. *Ryan*, *Omniping*, *Victoria and Ryan*) instead of bare `com.google.Chrome`, by fixing an AX-title clobber and distinguishing separate `--user-data-dir` instances.

**Date:** 2026-06-14
**Status:** confirmed (root cause reproduced; ready for `/code-foundations:plan`)
**Open questions:** none blocking. One product choice deferred to plan (display string format — see §6).

---

## 1. Problem

The picker shows every Chrome window with the subtitle `com.google.Chrome` and no profile. Two distinct identity layers are collapsed:

| Layer | Example (live, this machine) | Correct source | PID-derivable? |
|-------|------------------------------|----------------|----------------|
| Separate Chrome **process** (own `--user-data-dir`) | PID 66813 → `/tmp/chrome-cdp-profile`, PID 22364 → `/tmp/chrome-cdp-profile-2` (CDP automation) | process args `--user-data-dir` | ✅ yes |
| **Profile inside one process** | *Ryan*, *Omniping*, *Victoria and Ryan* — all under PID 32915 (the real Chrome) | AX window title suffix | ❌ no — same PID |

The key constraint: a single Chrome process hosts multiple profiles that **share one PID**, so PID alone cannot separate *Ryan* from *Omniping*. Only the AX window title (or the toolbar avatar button's AX label) carries the in-process profile. There is no public AX attribute named "profile".

---

## 2. The profile signal: AX window title

Chrome encodes the profile in the window's `kAXTitle`:

```
<page title> - Google Chrome - <ProfileName> (<email>)
```

Reproduced live (System Events + a standalone Swift probe both agree):

```
Publishing a site to upubli.sh - Claude - Google Chrome - Ryan (ryanthedev.com)
Developers – OMNIPING LLC – Stripe … - Google Chrome - Omniping (omniping.dev)
Monkeytype | A minimalistic, customizable typing test - Google Chrome - Ryan (ryanthedev.com)
New Tab - Google Chrome - Victoria and Ryan          ← local profile, no signed-in email
```

Notes:
- The title is **self-sufficient** for name + email in the common (signed-in) case.
- A single-profile instance (the CDP `/tmp/...` dirs) omits the suffix entirely: `… - Google Chrome`. For those, the *instance* identity is the `--user-data-dir`, not a title suffix.
- theGrid **already has the parser**: `ChromeEnricher.profilePattern` = `- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$` (`Picker/Enrichment/ChromeEnricher.swift:33`), plus a `Local State` `info_cache` name→dir→`user_name` map for the email. The parser is correct and unused-in-practice because it never receives the suffixed title.

---

## 3. Root cause: the AX title is captured, then clobbered

**The polled read works.** A standalone probe replicating theGrid's *exact* path —
`AXUIElementCreateApplication(pid)` → `AXUIElementSetMessagingTimeout(0.5)` → `kAXWindowsAttribute` → per-window `_AXUIElementGetWindow` ID match → `kAXTitleAttribute` — returns the **full profile-suffixed title** for every window of PID 32915. So both earlier hypotheses are **disproven**:

- ❌ element-match miss — the match succeeds (4/4 windows resolve their CGWindowID)
- ❌ 0.5s messaging-timeout race — read completes well under budget, returns full string

**The real cause is an unconditional overwrite.** Of the five places that write `axTitle`, four guard `!axTitle.isEmpty`; one does not:

| Site | Source | Guarded? |
|------|--------|----------|
| `StateManager.swift:703` | polled `getAXProperties` | ✅ |
| `StateManager.swift:1217` | polled, in `refreshWindows` | ✅ |
| `StateManager.swift:1652` | polled | ✅ |
| `StateManager.swift:1714` | polled | ✅ |
| **`StateManager.swift:1898`** | **`kAXTitleChangedNotification` event** | **❌ unconditional** |

Chain of the bug:
1. `kAXTitleChangedNotification` fires (Chrome emits these frequently — every tab/page title change, including mid-load transitions).
2. `ApplicationObserver.getWindowTitle(from:)` (`ApplicationObserver.swift:322`) does `AXUIElementCopyAttributeValue(element, kAXTitle…)` and returns the value as-is. When AX returns `.success` with an **empty string** (transient state), it returns `""` — non-nil, so the `if let title = …` at `:247` passes.
3. `handleWindowTitleChanged` (`StateManager.swift:1894`) executes `window.axTitle = title` with no emptiness check → the good full title is overwritten with `""`.
4. Nothing restores it: the polled writers only *set* non-empty, they don't run on a tight enough cadence to undo the clobber, so the dump shows `axTitle == ""` for exactly the four real windows.

This explains the dump precisely: real windows → `axTitle == ""` (clobbered), helper/child CGWindows → `axTitle == nil` (never matched an AX window, correct).

---

## 4. Fix shape (for the plan, not prescriptive)

Three independent, additive changes. (1) is the actual bug; (2) is belt-and-suspenders; (3) is the second identity layer.

### (1) Stop the clobber — required
Guard the notification writer so it matches the other four. Either:
- `getWindowTitle` returns `nil` for empty (`ApplicationObserver.swift:326`), or
- `handleWindowTitleChanged` guards `!title.isEmpty` before assigning (`StateManager.swift:1898`).

Prefer guarding at `handleWindowTitleChanged` (single chokepoint, intent-local). An empty AX title is never information we want to persist over a known-good one.

### (2) Re-poll on enrich — robustness
At picker build time, if a `com.google.Chrome` window's `axTitle` is empty or lacks the ` - Google Chrome - ` suffix, call the existing `refreshWindowAXProperties(windowID)` (`StateManager.swift:690`, proven to return the full title) and enrich from that. This guarantees correctness even if a clobber slips through, and covers windows whose title settled before observation started. `WindowSource`/`WindowEnricher` is the integration point (`Picker/WindowSource.swift:58-63`).

### (3) Surface `--user-data-dir` per PID — instance distinction
To distinguish separate Chrome processes (CDP/automation vs the real browser), read each Chrome PID's launch arguments and extract `--user-data-dir`.
- **Reading args without a subprocess:** `sysctl` with `KERN_PROCARGS2` (consistent with `ChromeEnricher`'s "file I/O only, no subprocess" note). `proc_pidpath` gives only the executable path, not args — insufficient.
- Cache per PID (args are immutable for a process lifetime).
- When `--user-data-dir` is absent → the default `~/Library/Application Support/Google/Chrome` (the multi-profile instance). When present and not the default → label by the dir basename (e.g. `chrome-cdp-profile`) and treat its sole profile as `Default`.
- This also makes the stable picker ID unique across instances that happen to share a profile display name.

---

## 5. Why not the alternatives

| Alternative | Verdict |
|-------------|---------|
| Walk AX subtree for the avatar/profile button label | Works, but heavier (tree walk per window) and the title already carries the same data. Keep as a last-resort fallback only. |
| AppleScript / `System Events` per window | Subprocess + slower + permission surface; the in-process AX read is strictly better and already wired. |
| Distinguish profiles by PID | Impossible for the in-process case — shared PID. Only valid for separate-instance case (which §4.3 handles via args, not PID identity). |

---

## 6. Deferred to plan (product, not technical)

- **Display string:** title already yields `Ryan (ryanthedev.com)`. Decide subtitle format when both a profile name *and* a user-data-dir label exist (e.g. `Ryan · ryanthedev.com` vs `Ryan (cdp-profile)`). The existing `EnrichmentResult(subtitle:)` shape supports either.
- **Profiles with no signed-in email** (`Victoria and Ryan`): subtitle is just the name — already handled by `ChromeEnricher`'s empty-email branch.

---

## 7. Evidence index (file:line)

- Parser (correct, starved of input): `grid-server/Sources/GridServer/Picker/Enrichment/ChromeEnricher.swift:33,54,96`
- Polled AX read (works): `grid-server/Sources/GridServer/StateManager.swift:627` (`getAXProperties`), `:738` (`extractAXProperties`), `:754` (title read)
- Re-poll helper (reuse for fix §4.2): `StateManager.swift:690` (`refreshWindowAXProperties`)
- The clobber: `StateManager.swift:1894` (`handleWindowTitleChanged`), `:1898` (unconditional write)
- Empty-title source: `ApplicationObserver.swift:246` (notification case), `:322` (`getWindowTitle`)
- Enrich integration point: `Picker/WindowSource.swift:51-63`, `Picker/Enrichment/WindowEnricher.swift:39,58`
- Separate-instance evidence: PIDs 32915 (default), 66813 (`/tmp/chrome-cdp-profile`), 22364 (`/tmp/chrome-cdp-profile-2`)

---

## Next

```
/code-foundations:plan .code-foundations/research/2026-06-14-chrome-profile-identity-picker.md
```
