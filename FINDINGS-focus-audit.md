# theGrid — log evidence (from thegrid-server.json + .json.1)

## Impact (both logs, per-action failure rate)
| action | total | with failure event | rate |
|---|---|---|---|
| focus.prev | 335 | 53 | 15.8% |
| focus.next | 198 | 40 | 20.2% |
| focus.down | 99 | 21 | 21.2% |
| focus.left | 142 | 12 | 8.5% |
| focus.right | 123 | 9 | 7.3% |
| focus.up | 171 | 5 | 2.9% |
| window.move | 137 | 44 | 32.1% |
| layout.apply | 134 | 50 | 37.3% |

**140 / 1068 focus commands (13%) hit a failure event.**

## BUG A — zombie resurrection loop (root cause)
kitty wids 1130, 2514, 8563, 8586. Each cycled **154 times** over ~6 days:
validate.win.untracked -> reconcile.win.create(cell) -> ax.fail(not_in_list)
-> validate.win.prune(ax_orphan, cycles:2) -> repeat ~50s later.
- pids 39899/5417/74115/6925 are ALL LIVE kitty processes (verified via ps).
- So: the untracked enumerator and the AX window list disagree for a live pid.
- Collateral: **23 REAL windows** pruned then re-added to a DIFFERENT cell
  (wid 1741: right,left,left,right,right,right,right,left,left). = "things get lost".
- `validate.orphan.reset.all` exists (clears the orphan counter) — suspect it makes the loop unbreakable.

## BUG B — windows dropped at create
- reconcile.win.create.bail 2849 (live) + 6417 (archive) vs 386 successful creates.
- 1944 bails = role:nil subrole:nil w:0 h:0 from `ev.win.create src:"poll"` (AX not ready).
- 1778 distinct wids: 269 destroyed <5s (benign), 922 never destroyed, only 6 later reconciled.
- **16 wids never reconciled yet later emitted real win.focus / ev.win.move / ev.win.resize**
  (wid 110: 35 later events incl. win.focus; 9236/9246/9247/9248: 24-77 events each).
- Other bail reasons: 445 AXWindow/AXUnknown, 251 AXSystemDialog, 156 AXHelpTag,
  30 no_layout, 10 not_in_state, 3 not_standard, 2 AXWindow/**AXStandardWindow** (suspicious).
- Prior attempted fix: 9a1a257 "re-query AX properties for nil-role windows during poll".

## BUG C — focus event race (workspace vs AX observer)
ts 1789330307, cross-display `focus up`:
1. ax.focus{pid:91674, wid:9736}  (our deliberate focus, display 89ED320F/space 6)
2. ev.focus{src:workspace, trigger:appActivated, wid:**9244**}  <- WRONG window, other display
3. win.focus 9244 -> bdr.retarget -> bdr.assignments for the wrong display
4. ev.focus{src:ax(Chrome), trigger:windowActivated, wid:9736} -> all redone
Also ts 1789330311: ev.focus{src:workspace, appActivated, **wid:0**}.
Counts: 229+821 reconcile.focus.suppressed, 161+288 sweep.correct (gridWid != osWid),
5+16 focus.seq.reject, 186+3354 warn.space.derive_override.

## BUG D — focus target selection inside a cell
ts 1789330311 `focus down` into space3/cell right. state.json: windows [9828,328,9234,9239,9249],
lastFocusedIdx:1, lastFocusedWid:328. Target chosen: **1130 (zombie) FIRST**, failed,
then fell through to 9828 — not lastFocusedWid(328).
cmd.err tally (both logs): 52+26 noCellInDirection, 14 allWindowsUnfocusable, 8 noDisplayInDirection,
8 noLayout, 9 noCellsWithWindows, 2 focusFailed(11874), 2 noFocusedWindow.

## Minor
- state.json `displaySpaces: {"display-1": ["5","999"]}` — key `display-1` and space `999`
  appear ZERO times in either log; real displays are FCEC43D7… / 89ED320F…. Stale synthetic
  state never pruned.
- 22x `"display":"nil"` and 4x `"display":""` in logs — unresolvable display for a window.
- CLAUDE.md documents `thegrid-cli.json`; no such file exists in ~/.local/state/thegrid.
- Churn: GridReconciler 16 commits, GridFocus 10, StateValidator 7 — long chain of symptom patches.

---
# AGENT B RESULT — BUG B root cause: stale subrole cache (not a missing retry)

- Bail site: `GridReconciler.swift:813-825` -> `gridState.rejectWindow(id)` = **permanent** set insert.
  Rejected windows are then skipped by layout forever: `GridApply.swift:608-609`.
- Retry paths DO exist: `rejectedWindowSweep()` `GridReconciler.swift:543-568` (300ms timer, `:458-461`)
  and `handleWindowMoved` unreject `GridReconciler.swift:1371-1397`.
  **But over 4 days: sweep.unrejected = 3, reconcile.win.unrejected = 0, vs 922 stuck wids.**
- WHY the sweep never fires: `isTileable` (`GridAssignment.swift:108-128`) gates on
  dimensions >= 100 AND subrole in {empty, AXStandardWindow}.
  `StateManager.updateWindowFromPoll` (`:1672-1684`) re-queries AX **only when `role == nil`**,
  and writes role+subrole together (`:1675-1676`). A transient `AXUnknown` subrole during app
  startup gets cached permanently; role is now non-nil so it is never re-queried. Dead forever.
- **This is already documented as confirmed-and-unfixed in-tree**: `StateManager.swift:1650-1668`
  says a transient AXUnknown subrole is never re-queried and "245 windows with real dimensions
  were bailed as not_tileable on that basis". Deferred over actor-stall cost (~11 blocking IPC/window).
- The 3 rescues prove it: wids 2545/2567 (the "anomalous" AXStandardWindow bails) were
  dimension-only rejections with clean subroles -> recovered. Subrole-poisoned ones never do.
- Confirmed real windows lost this way: 2884/2904/3025 (3840x1080), 2763 (713x966),
  2762 (632x858), 2464/2466/2470 (448x374).
- Bail reason verdicts: AXWindow/AXUnknown 445 = THE BUG; AXSystemDialog 251 + AXHelpTag 156 = correct;
  no_layout 30 (`:808`) terminal no retry; not_in_state 10 (`:790`) terminal no retry.
- Fix: narrow requery guard `StateManager.swift:1672` to `role == nil || subrole == "AXUnknown"`,
  bounded to wids in `rejectedWindows`, batched per-pid (pattern from `StateValidator.pruneAXOrphanedWindows`),
  with a retry budget. Write subrole only on AX success, gated to AXUnknown -> AXStandardWindow.
  Optionally give `not_tileable` the same grace window `not_standard` has (#41, `:828-843`).
- `rejectedWindows` is cleaned on destroy (`GridState.swift:542-546`) — no unbounded growth.
- **CROSS-LINK:** `sweep.unrejected wid:1130` at ts 1788835610 is what first admitted zombie 1130
  into a cell. The unreject path FEEDS BUG A's resurrection loop.

---
# AGENT D RESULT — BUG D root cause: every cell insert steals lastFocusedWid

- Selection algorithm `focusCellByID` `GridFocus.swift:418` is CORRECT:
  priority lastFocusedWid > lastFocusedIdx > first (`:443`, `:447-467`). Not index-0/array-order.
- **The bug is upstream.** `GridState.assignWindow` `GridState.swift:419-421`:
      cell.windows.append(windowID)
      cell.lastFocusedIdx = insertionIndex
      cell.lastFocusedWid = windowID     // unconditional focus steal
  Same defect in `prependWindow` `:450-451` and `insertWindow` `:471-472`.
  VERIFIED directly in source.
- Chain: reconciler re-adds zombies via `assignWindow` (`GridReconciler.swift:955`) in order
  8563,2514,8586,1130 -> each overwrites lastFocusedWid -> **last added (1130) wins** ->
  focusCellByID targets 1130 first.
- Proof: `focus.restore.stale` occurs **0 times** in the whole log. That branch (`:454-461`)
  fires only when lastFocusedWid is set but NOT found. Absence proves it was set AND found = 1130.
- Fall-through deterministic: `focusCandidateOrder` `:402-406` rotates (start+n)%count;
  start=8 (1130) -> next is index 0 = 9828. Never consults prevFocusedWid.
- `lastFocusedIdx` staleness CONFIRMED (secondary): `removeWindow` `GridState.swift:499-501`
  only CLAMPS, never decrements when a window before it is removed -> idx/wid silently desync.
  Masked today because wid wins; surfaces when wid is zeroed (`:502-503`), and that path logs NOTHING.
- `--extend`/`-m` clean: no target-selection side effects (`:9-10`, `:158`, `:170`, `:208-210`).
- Commit 5193ec2 IS a mask (keep it as defense, but it isn't the fix). `allWindowsUnfocusable`
  can fire with good windows present — zombies consume attempts, each costing a real AX round-trip.
- FIX: guard the focus-pointer write in assignWindow/prependWindow/insertWindow with
  `if cell.lastFocusedWid == 0`. Deliberate focus goes through `setFocus` `:751` — the only
  place that should move the pointer. Secondary: remap idx on remove instead of clamp.
  Third: jlog the silent `lastFocusedWid == 0` else-branch `:464-466`.
- Also flagged: `pickTargetCell` `GridReconciler.swift:947-952` prefers the CURRENTLY FOCUSED cell
  -> re-added windows land wherever the user happens to be = the 23 windows bouncing left/right.
  `GridReconciler.swift:1091` uses `prependWindow`, forcing index 0.

---
# AGENT C RESULT — BUG C root cause: workspace wid is derived wrong + suppression is asymmetric

- `WorkspaceObserver.swift:181-202`: seq stamped synchronously `:188` (correct), but the **wid is
  read inside the Task** `:191` via `getFocusedWindowID(pid)` -> `kAXFocusedWindowAttribute` on the
  **application** element (`:205-224`). Two faults: (a) async lag — reads "focused now", not at
  notification time; (b) wrong granularity — one per-app value, lags for multi-window/multi-display apps.
- Correct contrast: AX path `ApplicationObserver.swift:160-163` takes wid from the callback
  **element itself** — the element IS the newly focused window.
- MEASURED (pre-wipe log): when appActivated was followed within 2s by windowActivated, the wids
  **disagreed 78 times vs agreed 11** — workspace-derived wid wrong ~88% of the time.
- wid 0 is inert: real value is nil; logger renders `?? 0` at `EventRouter.swift:325`; both consumers
  guard (`StateManager.swift:279`, `GridReconciler.swift:1107`). Silently dropped activation. Low priority.
- **CORE BUG — asymmetric suppression.** `reconcile.focus.suppressed` `GridReconciler.swift:1106-1115`
  guards ONLY the reconciler. `StateManager.swift:278-281` calls `handleWindowFocused` **unconditionally**.
  So on the bogus 9244 event `applyWindowFocus` `:867-872` still wrote focusedWindowID=9244,
  wrong activeDisplayUUID, wrong activeSpaceID, and via `updateActiveSpace(trackLastFocused:true)`
  `:857-860` PERSISTED `lastFocusedWindowID`. The reconciler declined; StateManager applied it anyway.
- Sequence gate `FocusOwnershipPolicy.swift:31-33` is `incomingSeq >= lastAppliedSeq` — pure staleness,
  **no wid validation, no source weighting**. Wrong-wid + fresh seq passes AND raises lastFocusSeq
  (`StateManager.swift:1976`). Confirms the gate cannot catch this.
- **sweep.correct is downstream — MEASURED: 131 of 162 (81%)** were preceded within 3s by a workspace
  appActivated carrying the same wid the sweep then corrected to. `focusSweep`
  `GridReconciler.swift:471-490` reads the poisoned `metadata.focusedWindowID` `:482` and rewrites
  GridState cell focus `:519`. Poisoned metadata OUTLIVES the suppression window. This is the
  mechanism by which a wrong focus becomes a wrong CELL ASSIGNMENT.
- `warn.space.derive_override` = NOT a bug. `SpaceDerivationPolicy.swift:107-110` Rule 4: a visible
  window is on its display's current space, overriding SkyLight's ~3s-lagged report. Just misnamed —
  rename to `spc.derive.override` (186+3354 by-design events carrying a `warn.` prefix).
- FIX (ordered): (1) treat `.appActivated` as a hint, not a focus assertion — skip
  `handleWindowFocused` in `StateManager.swift:278-281`, let AX windowActivated set focus.
  Kills the 78/11 wrong writes and ~81% of sweep.correct. (2) Make suppression symmetric.
  (3) Add source rank to `FocusOwnershipPolicy.swift:31` (prefer axObserver over workspaceObserver).

---
# BUG E — `make run` destroys state + logs (found live, mid-session)

`Makefile:299` in the `run:` target — the command CLAUDE.md documents as "Full rebuild and restart":
    @rm -f ~/.local/state/thegrid/*.json
Deletes **state.json** (the entire saved grid layout) AND **thegrid-server.json** (all diagnostics),
plus picker-history/notifications/grid-viewer/imessage-watcher/tmux-cache.
- Fired at 15:19 this session; took 9.8MB of log with it. VERIFIED: no `log.rotate` event in the
  new file, `.json.1` untouched from Sep 6 (glob doesn't match `.json.1` — only reason the archive lived).
- `JSONLogger.writeBatch` `JSONLogger.swift:133-146` is correctly append-only (seekToEnd) — the
  logger is NOT at fault. Purely the Makefile.
- VERIFIED state.json is now empty: every cell `windows: []`. The user's layout is gone.
- Stale `displaySpaces: {"display-1": ["5","999"]}` SURVIVES the wipe and is re-serialized —
  `display-1`/space `999` appear 0 times in either log; real displays are UUIDs. Never validated/pruned.

# BUG F — rebuilt binary loses Accessibility (TCC), server runs blind anyway
New v0.9.0 log opens with `ax.permission.denied`, `warn.ax.permission`, then 540 `ax.fail`,
60 `ax.observer.create.failed`, `bfd.err.tap` (event tap dead = hotkeys dead).
`PermissionChecker.swift:13-18` detects it and `main.swift:93` logs a warning — **but the server
continues into a fully degraded state instead of halting or surfacing loudly.**
theGrid is non-functional on this machine right now until Accessibility is re-granted.

# BUG G — no single-instance guard; a second server silently steals the socket
`SocketServer.start()` `SocketServer.swift:25-27` calls `cleanupSocket()` which **unconditionally
unlinks the existing socket path** before bind — no check for a live owner, no EADDRINUSE path.
Observed live: `lsof /tmp/grid-server.sock` -> pid 38173 (a Sep-7 binary), while the log records a
v0.9.0 `srv.start` + `sock.start` today at 15:19. `thegrid ping` fails with
"Cannot connect to /tmp/grid-server.sock" while the server is demonstrably alive and logging
(srv.alive, bfd.dbg.health). Two builds tangled over one socket path.

---
# AGENT A RESULT — BUG A root cause: `role` is a latched one-way field + prune clears rejection

RUNTIME PROBE (new evidence, queried AX live):
    pid 39899: AX window count = 0     pid 5417:  0
    pid 74115: 0                       pid 6925:  0
    pid 44535: 1 -> cgid=328 AXWindow (the live one)
Processes alive, ZERO AX windows. So NOT a CG-vs-AX enumeration disagreement — a latched stale field.

- The two oracles:
  * `validate.win.untracked` <- `GridReconciler.adoptUntrackedTileables()` `:269-292`, gate `:282`
    -> `isTileable(window:)` `GridAssignment.swift:108-128` = **cached WindowState.role, NO AX call**.
  * `ax_orphan` prune <- `StateValidator.getAXWindowIDs(pid:)` `:305-325` = **live AX kAXWindowsAttribute**.
- `isTileable` returns true iff `window.role == "AXWindow"` (`GridAssignment.swift:127`) and role is a
  ONE-WAY RATCHET: `refreshWindows()` re-queries role (`StateManager.swift:1296-1298`) but is called
  from ONE place, `refreshCompleteState()` `:373` — **startup only**. The per-poll path re-queries
  only when already nil: `if window.role == nil` `StateManager.swift:1672`. Fills, never clears.
- wid 1130 latched role:AXWindow on Sep 7. Its AX window vanished with no destroy notification;
  SLS still returns bounds so `pruneDeadWindows` `StateValidator.swift:221` correctly won't prune it
  as dead. Record is immortal and permanently lies about being tileable.
- AX success-with-empty-array -> `getAXWindowIDs` returns `Set()` not `nil` (`:313-314`), so the pid
  is NOT skipped and its wids are marked orphaned. That half is correct; adoption is the wrong half.
- `cycles:2` (`StateValidator.swift:35`): map rebuilt fresh each cycle from stillOrphaned `:267-271`,
  count deleted on prune `:276`. Counter works as designed — nothing ever escalates, so no termination.
- **TOMBSTONE: none, and worse.** `removeWindowFromAllSpaces` ends with
  `rejectedWindows.remove(windowID)` `GridState.swift:547` — the ax_orphan prune actively CLEARS the
  rejection flag that `adoptUntrackedTileables` checks at `GridReconciler.swift:280`.
  **Pruning a zombie makes it MORE adoptable.** That closes the loop. VERIFIED in source.
- `pickTargetCell` `GridReconciler.swift:1727-1742` prefers the currently focused cell `:1732-1737`
  = why the 23 real windows wandered between cells.
- FIX: (primary) make adoption use the SAME live-AX oracle as pruning — batch per-pid using the
  logic already in `StateValidator.getAXWindowIDs`, skip wids absent from the live set. ~15 lines.
  (A) unlatch role at `StateManager.swift:1672` — per-pid batched requery that also CLEARS role when
  absent; the deferred-work comment at `:1660-1668` already scopes this.
  (B) gate `GridState.swift:420-421` behind `makeFocused: Bool = false`.
  (C) per-wid last-cell memory surviving a prune, so re-adoption restores the prior cell.
  (backstop) drop `GridState.swift:547` or give ax_orphan prunes a tombstone with backoff.
- Redundancy: 5193ec2 exists solely to survive zombies in cells (79 firings) — keep as defense,
  but it should stop firing. 44b0971 ("sample visibility fresh instead of latched isHidden") is
  **the same anti-pattern one field over**.
- Noted: `getAXProperties` sole-window fallback `StateManager.swift:649-670` (gated `:615-621`) is a
  second independent route to "phantom passes isTileable" for apps with exactly one unresolvable window.

---
# THE UNIFYING PATTERN (verified in source, GridAssignment.swift:108-128)

`isTileable` is a pure function of CACHED AX data that is never invalidated:
    if window.isMinimized || window.isHidden || window.level != 0   <- isHidden latched
    ... dimension gate ...
    let subrole = window.subrole ?? ""                              <- subrole latched  (BUG B)
    return window.role == "AXWindow"                                <- role latched     (BUG A)

  isHidden -> fixed in 44b0971
  subrole  -> BUG B, documented as confirmed-and-deferred at StateManager.swift:1650-1668
  role     -> BUG A, unfixed

ONE root defect, three fields. Every symptom patch so far has fixed one field at a time.

---
# VERIFICATIONS DONE BY ME (not agent-reported)

1. AGENT C's core claim CONFIRMED — `StateManager.swift:278-281`:
       case .focusChanged(let state):
           if let windowID = state.windowID {
               await handleWindowFocused(windowID, seq: state.seq)   // UNCONDITIONAL
           }
           switch state.trigger {
           case .spaceSwitched: await handleSpaceChanged()
           case .appActivated: break        // <- author intended appActivated to be a NO-OP
           default: break
           }
   The trigger switch explicitly treats `.appActivated` as `break`, but the focus write happens
   ABOVE the switch, so the bogus wid is applied anyway. The intent is in the code; the guard is
   just in the wrong place.

2. C's correlation RE-DERIVED on the surviving archive (`thegrid-server.json.1`, reproducible):
   appActivated followed within 2s by windowActivated -> **wids DISAGREE 457, AGREE 90 = 84% wrong**.
   (C measured 78/11 = 88% on the now-deleted live log; same conclusion, larger sample.)

3. Agent line numbers reconciled — no conflict, different granularity. Multiple admission points:
   `adoptUntrackedTileables` :269, `rejectedWindowSweep` :543, `assignWindow` called at
   :875, :894, :955, :1822, `prependWindow` at :1091, `pickTargetCell` helper at :1727.
   => A fix must cover EVERY admission point or B's subrole fix re-feeds A's loop via unreject.

4. LIVE SERVER STATE — corrected. pid 38173 `lstart` = Sep 7 21:43:41 = exactly the pre-wipe
   `srv.start` ts 1788835421. So **38173 is the v0.8.0 server from Sep 7, still running and still
   writing the log** (log growing: ts 1789331111). The v0.9.0 process that logged today's
   `srv.start` + `ax.permission.denied` + `bfd.err.tap` + `bfd.err.start` is GONE from ps, with
   no `srv.atexit` and no crash report. So:
     - make run's `pkill -9 -f grid-server` did NOT kill 38173 (failure swallowed by `|| true`)
     - v0.9.0 started without AX, `cleanupSocket()` `SocketServer.swift:25-27` UNLINKED the live
       socket out from under v0.8.0, failed its event tap, and exited
     - 38173 now listens on an orphaned inode; the path holds a dead socket
   => NOT "theGrid is dead": hotkeys likely still work (v0.8.0 has AX); CLI/MCP are dead
      (`thegrid ping` fails). State + logs wiped. NEEDS USER CONFIRMATION that they ran `make run`.

5. NOT INVESTIGATED — flagged for follow-up: `window.move` fails at 32%, and
   **48 of 48 `sls.move` calls (100%) emit `warn.move.sls_unverified`** with actual != expected
   (consistently expected:3 actual:6 or vice versa). Every cross-space window move fails SLS
   verification. Second-worst action after layout.apply; no agent was dispatched on it.
