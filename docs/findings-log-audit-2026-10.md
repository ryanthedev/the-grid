# theGrid — log audit across all machines (2026-10-14)

**Status: deployed to Mac Studio with `make run` on 2026-10-15 00:36. `swift test`
552/552; under `--sanitize=thread` 552/552 with 0 race warnings. ska and vana (where the crashes
are) get it only through a release.**

None of these changes write to user config or state. `TileOverrides` is in memory, the crash
handler writes only the server log. The one config edit (the iPhone Mirroring rule on Studio) was
made at the owner's request, appended to the existing `appRules` list.

Sources: `thegrid-server.json*` from Mac Studio (`92c1dc0`), ska and vana (both `a665c54`, 0.9.4),
Aug 2 – Oct 14. Error analysis restricted to events since Oct 8 to skip already-fixed bugs.
linode and prism-agent are Linux and don't run theGrid.

| # | Finding | Status |
|---|---------|--------|
| 1 | Server crashes ~once per machine per 1–2 weeks; 5 since Sep 15 | Plausible cause fixed (below); only ska's SIGTRAP stack fits it, the SIGSEGVs have no backtrace |
| 2 | Crash handler `_exit`ed, so macOS never wrote a crash report for SIGSEGV | Fixed: handler logs a `srv.fatal.bt` backtrace line, still exits silently |
| 3 | SIGTRAP (Swift traps, malloc aborts) had no handler; logged as `exit: unknown` | Fixed |
| 4 | Reconciler events run in parallel; Task refs and the fence written from several threads | Fixed (minimal set); other races deferred |
| 5 | iPhone Mirroring floats (no fullscreen button reads as picture-in-picture) | New `appRules` `tile: true` |
| 5b | `GridConfig.onReload` was never assigned: a saved config changed values but the grid never acted on them | Fixed: reload schedules the adoption sweep |
| 6 | vana logs a config validation error on every load | Harmless today; no change recommended |
| 8 | `CLAUDE.md`, `configuration.md`, `LAYOUTS.md` documented `thegrid config validate`/`sources`; neither exists | Fixed: docs point at `config show` and the log events |
| 7 | `663cea3` focus-steal guard never logged `focus.steal` on ska since deploy | Question for owner |

## 1. Crashes

| Machine | When | Signal | Uptime | Context |
|---|---|---|---|---|
| ska | 09-15 14:43 | SIGSEGV | 4.2 d | — |
| vana | 09-21 11:30 | SIGSEGV | 7 d | — |
| ska | 09-22 12:45 | SIGSEGV | 6.9 d | — |
| vana | 10-10 13:40 | SIGSEGV | 37 min | System Settings launching |
| ska | 10-14 12:54 | SIGTRAP: `BUG IN CLIENT OF LIBMALLOC: memory corruption of free block` | 4 d | Chrome for Testing launching |

- Only the ska 10-14 crash has a backtrace, because SIGTRAP bypassed our handler:
  `swift_task_create_commonImpl ← Task.init ← GridState.markDirty ← GridState.setFocus ←
  GridReconciler.focusSweep ← startSweepTimer closure`. That is where malloc noticed the
  damage, not where it happened.
- `heap_mb` from `srv.alive` is flat before every crash (ska 20–55, vana 51–53, vana 09-21
  ~114–151), so it is not a leak.
- The crashes predate `663cea3`, so the focus-steal guard is not the cause.
- Studio's many `exit: unknown` entries line up with dev rebuilds and are not crashes.

## 2–3. Crash reporter (`CrashReporter.swift`)

The handler wrote `srv.fatal` then called `_exit(128+sig)`. That kept crashes silent (launchd
restarts the server, no dialog) but left no backtrace: ReportCrash never ran.

Now, still before `_exit`, it writes one more JSONL line to the server log:

```
{"ev":"srv.fatal.bt","data":{"base":"0x104178000","frames":["0x1042d763c",...]},"ts":...}
```

Symbolicate against the same commit's binary:
`atos -o GridServer.app/Contents/MacOS/grid-server -l <base> <frames...>`. Checked with a test
crash: the frames resolve to `triggerCrashTest` → `GridServerCommand.run` → `main` with line numbers.

- **Why not a macOS crash report:** re-raising the signal (tried first) gives a full `.ips`, but may
  show a "quit unexpectedly" dialog for a window manager that already restarts itself. Unverified
  either way, so the silent path was kept.
- **Why raw addresses:** symbolizing in the handler (`backtrace_symbols_fd`) may allocate. After
  heap corruption that can hang the window manager, and launchd does not restart a hung process.
  `backtrace()` is warmed at install and only walks frame pointers; the rest is preallocated buffers.
- The backtrace lands in the log already collected from every machine.
- SIGTRAP added to `fatalSignals` (Swift traps and malloc aborts), so those classify as `fatal`.
- Only the crashing thread is captured.

## 4. Parallel event delivery and races (`GridReconciler`)

`EventRouter` is an actor, but `route` suspends at `await handler.handle(...)` and the actor
starts the next `route` meanwhile. `GridReconciler` is a plain class, so `handle()` runs on the
global pool: **events for it run in parallel on different threads**. The 300 ms sweep timer also
started a new Task each tick with no overlap guard, and `rejectedWindowSweep` makes blocking AX
calls (0.5 s timeout per app), so sweeps overlapped. Two comments claimed this path was serial
(`EventRouter.swift`, `GridReconciler.crossMoveGrace`); both corrected.

A double release of a Task reference frees a Task-sized block twice; the next `Task.init` of that
size (`markDirty`) trips over it. That matches the ska stack but does not prove it.

`ReconcilerConcurrencyTests` (new) fires 50 parallel move events and fence calls. Under TSan
**before** the fix: 13 race reports and the test process died with SIGTRAP. **After:** 0, passes.

| Shared state | Fix | Status |
|---|---|---|
| `membershipSweepTask` (rescheduled on every move event) | swap under `refLock` | Fixed |
| `wakeValidationTask` (TSan hit in the existing suite) | swap under `refLock`; clear after `await task.value` instead of inside the task | Fixed |
| `geometryReapplyTask` | swap under `refLock` | Fixed |
| `fence` (dictionary; acquire/release/isFenced/activeWindows) | each access under `refLock` | Fixed |
| Overlapping sweep Tasks | `sweepStartedAt` guard: a tick is skipped while the previous sweep runs; a claim older than 10 s is ignored so a hung sweep can't switch sweeping off | Fixed |
| `axAbsentStreak`, `axAbsentRetryAt`, `subroleRequeryAttempts`, `lastAXAbsentSkipped` | — | Deferred: loops contain `await`s |
| `notStandardGrace`, `notStandardExpired` | — | Deferred: same |
| `suppressedEvents`, `crossMoveGrace`, `pendingLaunchTarget`, `actionTokens` | — | Deferred |

`refLock` is one `NSLock`, only used through `withLock { }` and never held across an `await`.
TSan covers test-exercised paths only; it never touched AX, SkyLight or border code.

**Recommended follow-up:** move `GridReconciler` onto one serial executor (an `actor`, or a custom
`SerialExecutor`). That removes parallel writes for every deferred row at once. Interleaving at
`await`s stays as it is today. Larger change: synchronous callers (`acquireFence`, `beginAction`,
`endAction`, `noteCrossSpaceMove`, `setPendingLaunchTarget`) need `await` or a wrapper.

Also flagged, not fixed: `rejectedWindowSweep` makes blocking AX calls (`axWindowIDs`) from the
cooperative pool, against the house rule to keep blocking AX off it.

## 5. iPhone Mirroring and `tile: true`

iPhone Mirroring's windows are `AXStandardWindow` with close/minimize/zoom but **no fullscreen
button**. `classifyWindow` treats that as picture-in-picture and floats it unless the app is in the
hard-coded `terminalApps` list. The iOS Simulator tiles because its window has a fullscreen button.

New app rule field, by app name or bundle ID:

```yaml
appRules:
  - app: "iPhone Mirroring"   # or com.apple.ScreenContinuity
    tile: true
```

- Only bypasses the picture-in-picture check. Dialogs, sheets and modals still float.
- Published from `GridConfig.parseAppRules` to `TileOverrides` (lock-guarded) on every load and
  hot reload, because `classifyWindow` is a free function with no config handle.
- Live on Studio: rule appended to `config.local.yaml` (where `appRules` already lives; a rule in
  `config.yaml` would be replaced by the local list). Window 4212 joined the `left` cell 3 s after
  the reload, at its own 354×781 size.
- An already-floating window is adopted ~4 s after the config is saved: reload now schedules the
  membership sweep (`handleConfigReload`), also when the reload fails validation but the parsed
  config is in effect. Adoption re-classifies expired not-standard windows, so no relaunch.
- Removing the rule doesn't un-tile an already-tiled window until it reopens.
- "Welcome to iPhone Mirroring" has the same shape (standard window, no fullscreen button) and
  tiles too. It stays open after the phone window appears; close it.
- Fixed-size windows keep their natural size, positioned in the cell (`win.size.fixed`, same as
  the Simulator).
- Hotkeys stop working while iPhone Mirroring is focused: it turns on Secure Input
  (`bfd.secure_input.on`). Tiling doesn't change that.
- Tests: `TileOverrideTests` (5). Docs: `docs/configuration.md`.

## 6. vana config

`~/.config/thegrid/config.local.yaml` on vana has its own full `layouts:` list. Deep merge replaces
arrays, so it drops base `four-column`, which base `spaces."4"` uses. Every load logs
`err.grid.cfg: space 4 references unknown layout: four-column`. The rest applies.

**No action recommended.** vana has 3 spaces, so space 4's rule never runs; all 14 log hits are
the error line itself. The override is the owner's per-machine choice. Merging `layouts` by `id`
was considered and rejected: `@layout cycle` walks every defined layout (`getLayoutIDs()`), so base
layouts would reappear in vana's cycle.

## 7. Focus-steal guard (`663cea3`)

Never fired on ska since the Oct 10 deploy. It detects a steal by reading the app's
`kAXFocusedWindow`. The commit says Island's stealing window is not exposed to accessibility, so
the guard may be blind to the case it was built for. Is focusing Island working on ska now?

## Checked and not bugs

- `validate.skip.paused` ~2k/day on vana: the screen was locked (matches `ws.lock`/`ws.unlock`).
- `warn.space.derive_override` ~30–80/day: a deliberate, de-duplicated heuristic.
- Focus requests land 98–99% of the time on all three machines (by the next `ev.focus`).
- Log volume: `bfd.dbg.health`, `validate.start/end` and `srv.alive` are ~75% of lines. Left
  alone because they double as liveness evidence.
