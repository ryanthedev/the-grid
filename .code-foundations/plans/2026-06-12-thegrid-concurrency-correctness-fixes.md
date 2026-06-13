# Plan: theGrid Concurrency & Correctness Audit Fixes

**Created:** 2026-06-12
**Status:** in-progress
**Started:** 2026-06-12 21:36
**Current Phase:** 2
**Complexity:** complex
**Workspace:** worktree `.claude/worktrees/thegrid-concurrency-correctness-fixes` · branch `feature/thegrid-concurrency-correctness-fixes`

---

## Context

A four-lens audit of theGrid's server (`grid-server`, ~32K LOC Swift) surfaced **57 confirmed + 6 suspected** defects across focus ownership, the tiling pipeline, actor/concurrency discipline, and silently-swallowed errors, plus **64 silent failure paths** with no log line. Root causes cluster into four families: (1) no serialization on the command path — plain classes (`GridCommandRouter`, `GridReconciler`) fed by one unstructured `Task` per request/keypress/AX-notification; (2) event-dropping suppression that never replays; (3) space-migration firing on plain space switches, not just true reassignments; (4) systematically discarded AX/CG/SLS return codes. This plan fixes the full inventory.

The detailed per-finding spec (mechanism, fix-direction, evidence, log signatures, both verifier rationales) lives in **`.local/state/audit/bug-inventory-2026-06-11.json`** (and `.txt`). Each done-when item below references a finding by `#ID`; the build agent reads the audit entry for that ID to get the full mechanism and exact file:line.

Finding IDs marked `s` (e.g. `#29s`) are **suspected** — not confirmed end-to-end. They are handled instrument-then-confirm: the fix adds the proposed log signature, and the confirm-or-drop decision happens during that phase's UAT (never fixed blind).

---

## Constraints

- **Every fix ships with observable confirmation** — a passing test and/or a `jlog` signature demonstrable at build time and during **UAT of the PR**. Nothing lands without a way to verify it live.
- **Suspected findings are not fixed blind.** Each gets its instrumentation first; confirm-or-drop happens during UAT, honoring the audit's "suspected ≠ fix" rule.
- **Load-bearing instrumentation is in scope** and folded into the relevant fix phase (the silent-path log that proves a fix or confirms a suspected finding) — not a separate cosmetic logging sweep.
- **Conventions** (`docs/code-standards.md`): Swift actors for shared mutable state — never `DispatchQueue`+locks for new state; `jlog` event codes (`warn.<scope>.<reason>` / `err.<scope>` / `<scope>.<event>`); comments on their own line, never inline; port/adapter seams live in `Ports/` (behavior in the adapter, contract in the protocol); `[weak self]` + `guard let self else { return }` in escaping closures; never `Task {}` back into the same actor.
- **Delivery:** PR(s) with UAT. The serialization foundation (P1) is built first — it roots out the command-vs-command races and ships the primitives (serial executor, refcounted fence, generation counter, suppressed-event replay) the other phases consume.
- **No regression** in core flows (tile-on-create, focus nav, layout apply, space switch, sleep/wake); the window manager must stay usable between phases.

---

## Chosen Approach

**B — Serial command executor (queue).** A single serializer (Swift actor / serial executor) consumes commands one-at-a-time; `MessageHandler` and BFD submit to it instead of spawning a `Task` per request. Smallest blast radius, strongest command-vs-command mutual exclusion, exactly one new ingress seam. The existing actors (`GridState`, `StateManager`, `EventRouter`, `StateValidator`) are unchanged; `GridReconciler`/`GridCommandRouter` internals stay class-based but only ever run one command end-to-end at a time. **Fallback:** if a long-running command (e.g. a wake-gated dispatch) starves the queue under load, add a bounded concurrency lane for read-only commands.

The residual races approach B does **not** fix for free — event-stream-vs-command and TOCTOU-across-`await` (#13, #17, #42, #51) — are fixed in their cluster phases using the refcounted fence + monotonic generation counter P1 ships. (Those need the same fence/generation discipline under any of the three approaches considered.)

## Rejected Approaches

- **A — Actorize router + reconciler:** most idiomatic but largest blast radius (every call site + reentrancy review at every `await`), and does *not* fix TOCTOU-across-`await` on its own — still needs the same fences. Disproportionate disruption to a live daily-driver WM.
- **C — Unified actor mailbox (commands + AX/poll events through one serialized inbox):** most complete (kills command-vs-event races too) but highest risk on a live WM — latency if a handler is slow, deadlock if a handler re-enters the mailbox, 3s-poll backpressure. Hard to ship incrementally.

---

## Implementation Phases

### Phase 1: Serialization foundation
**Model:** opus
**Skills:** gof-design-patterns, ca-architecture-boundaries, cc-refactoring-guidance, cc-defensive-programming
**Gate:** Full

**Goal:** Serialize the command path and make `GridReconciler` shared state safe, shipping the four primitives the rest of the plan reuses.

**Scope:**
- IN: serial `CommandExecutor` at ingress; refcounted fence; monotonic generation counter; suppressed-event queue+replay; nudge session state made consume-once + isolated. Findings #3 #4 #5 #11 #12 #14 #50.
- OUT: per-cluster TOCTOU fixes (#13 #17 #42 #51 — they consume these primitives, fixed in P2/P3); event-vs-poll unification.

**Constraints:** Serializer preserves dispatch semantics (`awaitWakeCompletion` still honored). A nudge session must NOT hold the queue across keystrokes — enter/exit and each keystroke are discrete submits. Replay preserves arrival order. Swift actor, not locks (§8); never `Task{}` back into the owning actor (§1).
**Edge cases:** double `@nudge enter` racing the `nudgeKeyHandler != nil` check (token consumed once, handler stop-replaced); fence release with overlapping acquisitions (remove only at refcount 0); `executeAction` throwing must still drain the suppressed queue; replay of an already-gone wid is idempotent.
**Approach notes:** Approach B (serial executor) — user decision. Coalesce repeated same-direction nudge submits (#50).
**File hints:** `MessageHandler.swift:52`, `BFD/BFDManager.swift:137` (ingress); `Grid/GridCommandRouter.swift:158,779-830` (dispatch, nudge); `Grid/GridReconciler.swift:21,57-66,91-129,441-444` (class, suppression, fence, executeAction, event-drop).

**Depends on:** nothing — entry phase | **Unlocks:** P2, P3, P7 directly; P4, P5, P6 transitively
**Produces:**
- **Serial `CommandExecutor` seam** — `actor`/serial-executor with `func submit(_ command: String) async -> CommandResult` that `MessageHandler.handle` and `BFDManager.handleInternalCommand` call instead of `Task { await router.dispatch(...) }`. One command body runs end-to-end at a time.
- **Refcounted fence API** on the reconciler — `acquireFence(wid) -> FenceToken` / `releaseFence(token)`; the entry is removed only when the refcount reaches 0.
- **Monotonic generation counter** — `var generation: UInt64` bumped by `beginAction`/`executeAction`; readable by handlers + the focus sweep to detect a stale pre-`await` snapshot.
- **Suppressed-event queue + replay** — `windowCreated`/`windowDestroyed` arriving while `suppressionDepth > 0` are queued and replayed when depth returns to 0 (not silently dropped).
- Log seams: `cmd.submit`/`cmd.exec{inflight}`, `fence.acquire`/`fence.release{wid,depth}`, `reconcile.suppressed.queue`/`reconcile.suppressed.replay{event,wid,gen}`.

**Done when:**
- [ ] DW-1.1 (#11,#3): serial `CommandExecutor` actor exists; `MessageHandler`+BFD submit through it; 4 overlapping submits complete in submission order; `cmd.exec{inflight}` never exceeds 1 under a held-key burst.
- [ ] DW-1.2 (#5): two concurrent `layout cycle` submits no longer interleave — rapid double-apply yields one consistent layout id + cell map (no `cellNotFoundInLayout`).
- [ ] DW-1.3 (#14): fence refcounted — acquire×2/release×1 stays fenced; `fence.release{wid,depth}` logged; release of an unheld wid is a no-op.
- [ ] DW-1.4 (#4): concurrent double `@nudge enter` installs ≤1 CGEventTap, token consumed exactly once; after exit `suppressionDepth==0` and zero live taps.
- [ ] DW-1.5 (#50): held nudge key coalesces repeats and applies steps in order (none lost or back-stepped).
- [ ] DW-1.6 (#12): create/destroy during suppression queued + replayed at depth 0; a window created-while-suppressed becomes tracked; `reconcile.suppressed.queue`+`.replay{event,wid,gen}` logged.
- [ ] DW-1.7: generation counter increments per action and is readable by handlers/sweep (primitive for P2/P3) — unit test asserts monotonic increase.

**Difficulty:** HIGH
**Uncertainty:** Whether nudge-repeat coalescing changes feel (tune in UAT); whether any read-only command needs a concurrency lane (fallback noted in Chosen Approach).

---

### Phase 2: Space & wake state migration
**Model:** opus
**Skills:** cc-defensive-programming, aposd-simplifying-complexity, cc-control-flow-quality
**Gate:** Full

**Goal:** Migrate grid state only on a true macOS space-ID reassignment; reapply layouts correctly across wake, lock, and display reconfiguration.

**Scope:**
- IN: gate migration on true reassignment; `spaceActivated` vs `spaceIDReassigned`; numeric sort + significant-state guard in `migrateSpaceIDs`; `displayGeometryChanged` (frame diff) event + debounced reapply; lock-aware validator resume; zero-bounds guard; per-handler active-space re-resolve. Findings #2 #6 #20 #23 #24 #25 #26 #51 #52 + #62s #63s.
- OUT: cross-space window geometry (P4); the generation-counter primitive ships in P1.

**Constraints:** Never migrate/wipe a destination that already `hasSignificantState`. Validator resumes only when unlocked (track `com.apple.screenIsLocked/Unlocked` on `DistributedNotificationCenter`, §8). Migration reads P1's generation counter to skip stale snapshots. #51 re-resolves active space immediately before each mutating handler call.
**Edge cases:** fullscreen-space bounce (3→ephemeral→3) round-trips without loss; count-mismatched old/new lists at wake (#6 skip/partial + log); zero/degenerate display bounds at wake/dock-replug (#24); geometry-only change, same UUID set (#25); display index-vs-UUID join (#63s).
**Approach notes:** Suspected #62/#63 get their log first; confirm-or-drop in UAT.
**File hints:** `StateManager.swift:404-428,945-982,1744-1776,1888-1931`; `Grid/GridReconciler.swift:866-908,959-1000,1118`; `Grid/GridState.swift:205-277`; `Grid/GridApply.swift:136`; `WorkspaceObserver.swift:132-149`.

**Depends on:** P1 | **Unlocks:** P4
**Produces:**
- Migration gated on **OS-existence** (old space ID absent from refreshed `state.spaces`); a dedicated `spaceActivated` event distinct from `spaceIDReassigned` for plain switches.
- `migrateSpaceIDs` uses **numeric** space sort + refuses to overwrite a destination that already `hasSignificantState`.
- A `displayGeometryChanged` event (frame/visibleFrame diff, not just UUID-set) the reconciler reapplies, debounced.
- Lock-state tracking that gates validator resume on wake (resume only when unlocked).
- Zero/degenerate-bounds guard in `applyLayoutBody` and per-display refresh.

**Done when:**
- [ ] DW-2.1 (#2): `spaceIDReassigned` routes only when the old ID is absent from refreshed `state.spaces`; plain switches route `spaceActivated`; switching between two laid-out desktops preserves both — `state.space_migrated.live` no longer fires on a persistent round-trip.
- [ ] DW-2.2 (#6): `migrateSpaceIDs` sorts numerically + refuses to overwrite a `hasSignificantState` destination; `state.space_migrate.snapshot{old,new,paired}` logged.
- [ ] DW-2.3 (#26): apply re-resolves the space id before its write phase (or aborts on mid-apply migration) — no zombie-space write after a transition.
- [ ] DW-2.4 (#51): each mutating handler re-resolves active space immediately before acting; a queued `@state reset`/resize after a switch cannot hit the prior space.
- [ ] DW-2.5 (#23): validator resumes on wake only when unlocked — tiled windows survive a login-screen wake (no `ax_orphan` prune while locked).
- [ ] DW-2.6 (#24): zero/degenerate display bounds skip + log `err.layout.zero_bounds` instead of tiling to the corner.
- [ ] DW-2.7 (#25): geometry-only reconfig diffs frame/visibleFrame and reapplies (debounced) after a resolution/scaling/Dock change.
- [ ] DW-2.8 (#20,#52): the dead space-change + display-disconnect handlers are either fixed to fire or removed; borders resync after a switch.
- [ ] DW-2.9 (#62s,#63s): instrumentation added (`dsp.geometry.change`, display index-vs-UUID join trace); confirmed or dropped during UAT.

**Difficulty:** HIGH
**Uncertainty:** #62/#63 disposition pending UAT; multi-desktop-per-display data-loss is mechanically certain but unobserved on this machine (one tiled space/display today).

---

### Phase 3: Focus ownership & navigation
**Model:** opus
**Skills:** cc-control-flow-quality, cc-defensive-programming, gof-design-patterns
**Gate:** Full

**Goal:** Establish one authoritative focus-ownership path — no ping-pong, no empty-cell dead-ends, and real focus-failure propagation.

**Scope:**
- IN: real success/failure from `focusWindow`; verify via direct AX query; skip empty cells in directional focus; single ordered AX-notification pipeline; actor-isolated per-requested-window loop detector. Findings #7 #8 #13 #17 #21 #30 #35 #42 #43 + #59s.
- OUT: border repaint (P6 consumes the authoritative focus).

**Constraints:** One writer for "the focused window." focusSweep must consult P1's fence + generation counter and skip in-flight wids. Ordered pipeline replaces per-callback `Task{}` (single consumer, monotonic sequence); no `Task{}` back into the owning actor (§1).
**Edge cases:** nil `actualFocusedWID` must not pass verification vacuously (#43); focused window destroyed mid-command (#42 prune ordering); 3-window rotation (detector per-requested, not pair — #43); minimize resolves the window's tracked space, not the focused one (#30); restore skips a window that left the space (#59s).
**Approach notes:** #59s instrument-then-confirm in UAT.
**File hints:** `Grid/GridFocus.swift:92-263,318-432,766-792`; `Grid/FocusLoopDetector.swift`; `WindowManipulator.swift:458-519`; `ApplicationObserver.swift:342`; `WorkspaceObserver.swift:186-211`; `Grid/GridReconciler.swift:317-371,1052`.

**Depends on:** P1 (fence + generation counter; the ordered pipeline reuses the serial model) | **Unlocks:** P6
**Produces:**
- `focusWindow(...)` returns a **real** success/failure (Bool reflects the AX/CG/SLPS result; state focus set only on genuine success).
- Focus verified via a **direct AX focused-window query** (or synchronous state write), not the event-fed cache.
- Directional focus **skips empty cells**, falling through to the next candidate / wrap target.
- A single **ordered AX-notification pipeline** (one consumer, monotonic sequence stamps) replacing per-callback `Task {}`.
- Actor-isolated, per-requested-window loop detector (observes nil-actual; post-trip suppression).
- **`GridState.focusedWindow` write-on-success invariant** — the focused-window state is written only after genuine AX/CG confirmation (DW-3.1); P6 treats `GridState.focusedWindow` as the authoritative border target.

**Done when:**
- [ ] DW-3.1 (#21): `focusWindow` returns false on AX/CG/SLPS failure; state focus set only on success; `err.focus`/`warn.focus` fire on a real failure.
- [ ] DW-3.2 (#7): focus verified by a direct AX query (not the event-fed cache) — no spurious mismatch/double-raise in the stale-cache scenario.
- [ ] DW-3.3 (#8): directional focus skips empty cells to the next candidate/wrap target; pressing toward an empty cell focuses the next non-empty one (no `noWindowsInCell` dead-end).
- [ ] DW-3.4 (#13): focusSweep skips fenced wids + re-checks the generation counter before correcting; no focus revert mid-/post-command.
- [ ] DW-3.5 (#17): a single ordered AX-notification consumer with sequence stamps rejects stale focus events — no focus inversion while typing.
- [ ] DW-3.6 (#35): loop detector is actor-isolated (no array data race) — unit/TSan check.
- [ ] DW-3.7 (#43): detector observes the nil-actual case, keys per-requested-window, and suppresses after a trip; a 3-window rotation trips it.
- [ ] DW-3.8 (#42): dead-window prune is awaited before `setFocus` — correct successor focused after a close.
- [ ] DW-3.9 (#30): minimize removes the window from its tracked space via `findSpaceContaining` — cell slot freed regardless of focused display.
- [ ] DW-3.10 (#59s): restore-focus space-membership check instrumented (`win.focus.restore.skip`); confirmed or dropped during UAT.

**Difficulty:** HIGH
**Uncertainty:** Per-focus direct-AX-query cost (measure; acceptable for a hotkey path); #59s disposition pending UAT.

---

### Phase 4: Window creation, classification & adoption
**Model:** opus
**Skills:** cc-defensive-programming, welc-legacy-code, cc-control-flow-quality
**Gate:** Full

**Goal:** Ensure every tileable window reaches a cell or is logged, and close the create / launch / cross-space adoption races.

**Scope:**
- IN: `shouldUseSoleWindowFallback` guard in `WindowManipulator.getAXElement`; depth-0 adoption of unassigned tileables; pending-launch consume-before-await + bundle-id match + clear-on-fail; not_standard re-eval grace. Findings #15 #18 #31 #32 #40 #41 #57 + #29s #60s #61s.
- NOTE: the cross-display-move failure abort (#16) is owned by P5 (DW-5.4); P4 only relies on its result, it does not re-implement it.
- OUT: geometry of the placed window (P5).

**Constraints:** Reuse the exact `shouldUseSoleWindowFallback(resolved:soleWindowID:queriedID:)` helper from commit 1cf354e — don't fork the logic. Adoption runs at suppressionDepth 0 via P1's replay. Pending-launch consume happens before the first `await` in `handlePendingLaunchWindow`.
**Edge cases:** sole AX window resolving to a different CG id → don't substitute (#15); pid-less target claimed by a foreign window (#31); locked cell on an inactive space (#32 — move-to-space or defer); observer AX-register fail at launch (#40 bounded retry); not_standard from late-populated window buttons (#41); poll snapshot resurrecting a destroyed wid (#60s tombstone); transient `AXUnknown` subrole cached (#61s requery); deriveSpaceFromDisplay overriding SLS (#29s).
**Approach notes:** #29s/#60s/#61s are the suspected-race findings — instrument-then-confirm in UAT, NO blind edits.
**File hints:** `WindowManipulator.swift:57-85,336-422`; `Grid/GridReconciler.swift:404-408,423-428,603-665,698-807,1394-1446`; `StateManager.swift:945-982,1196-1212,1278-1372,1934-1958`; `Picker/ActionExecutor.swift`.

**Depends on:** P1 (suppressed-event replay, serial executor), P2 (correct space identity) | **Unlocks:** P5
**Produces:**
- `WindowManipulator.getAXElement` guarded by `shouldUseSoleWindowFallback` (same guard as `StateManager`, commit 1cf354e), logging when it fires.
- Tileable-but-unassigned windows logged (`validate.win.untracked`) and adopted at depth-0.
- Pending-launch target **consumed before the first `await`** + matched by bundle ID (not pid-less first-come); failed launch clears it.
- `not_standard` classification re-evaluated within a grace window instead of terminal bail.

**Done when:**
- [ ] DW-4.1 (#15): `getAXElement` applies `shouldUseSoleWindowFallback` and logs `ax.fallback{pid,wid,resolved,op}` when it fires; a phantom id no longer substitutes the real window.
- [ ] DW-4.2 (#18): pending-launch target consumed before the first await; event path + sweep cannot both claim it — exactly one window placed.
- [ ] DW-4.3 (#31): target requires a bundle-id match (not pid-less first-come); a failed launch clears the target + logs.
- [ ] DW-4.4 (#32): a locked cell on an inactive space moves/defers the window to that space instead of leaving it bounced.
- [ ] DW-4.5 (#40): observer-register failure retries with backoff; pid/app logged (`ax.observer.create.failed`).
- [ ] DW-4.6 (#41): `not_standard` is re-evaluated within a grace window (or on the next sweep) — a slow-button window tiles without reopen.
- [ ] DW-4.7 (#57): a pending claim is merged (not clobbered) by an in-flight apply.
- [ ] DW-4.8 (gap exposed by #12): tileable-but-unassigned windows (the terminal state of a create dropped during suppression) are logged `validate.win.untracked` and adopted at depth 0.
- [ ] DW-4.9 (#29s,#60s,#61s): instrumentation added (`warn.space.derive_override`, poll-readd tombstone trace, subrole-requery); each confirmed or dropped during UAT.

**Difficulty:** HIGH
**Uncertainty:** The three suspected race findings (#29/#60/#61) may resolve to "no fix needed" after UAT instrumentation.

---

### Phase 5: Geometry writes — move / resize / cell-ops / splits
**Model:** sonnet
**Skills:** cc-control-flow-quality, cc-defensive-programming
**Gate:** Standard

**Goal:** Make the geometry write paths compute and apply correctly.

**Scope:**
- IN: resize boundary delta sign for last-in-stack; preserve split ratios on membership change (recalculate); reposition displaced window after migration; cross-display-move failure abort; autoflow drop logging. Findings #10 #16 #19 #28 #48.
- OUT: nothing downstream (leaf).

**Constraints:** Use existing `recalculateSplitsAfter{Addition,Removal}` (`GridLayout.swift:781-825`), currently dead for this path — don't reinvent. Resize must match `adjustSplitRatio`'s sign convention. #16's `moveWindowToSpace`-success seam is shared with P4 — coordinate, don't double-fix.
**Edge cases:** focused window last in stack → negate delta or shift boundary index (#10); sole-window cell (no split); send-window equalizing both source+target cells (#28); displaced window logically migrated but never repositioned (#19); all-cells-locked autoflow drop (#48).
**File hints:** `Grid/GridResize.swift:93-96`; `Grid/GridLayout.swift:687-718,781-825`; `Grid/GridState.swift:339,415-419`; `Grid/GridCellOps.swift:118-127`; `Grid/GridWindowMove.swift:432`; `Grid/GridReconciler.swift:1426`; `Grid/GridAssignment.swift:370-372`.

**Depends on:** P1, P4 (acts on correctly-assigned cells) | **Unlocks:** none (leaf)
**Produces:**
- Resize boundary delta **sign correct** when the focused window is last in its stack.
- Split ratios **preserved** across membership change (recalculate, not equalize) — consistent with `setWindowAssignments`.
- Displaced-window migration **repositions** (applies cell layout) after reassignment.
- `assignAutoFlow` logs dropped windows when all cells are locked.

**Done when:**
- [ ] DW-5.1 (#10): grow grows / shrink shrinks the focused window even when it is last in its stack — unit test on a 2-window cell with the last window focused; `resize.split.done` reflects the correct direction.
- [ ] DW-5.2 (#28): split ratios preserved across send/assign (recalculate, not equalize) — custom ratios survive a cell-send in both source and target cells.
- [ ] DW-5.3 (#19): displaced-window migration calls `applyCellLayout` for the target (and vacated source) cell — geometry matches the new assignment.
- [ ] DW-5.4 (#16): cross-display move aborts state mutation when `moveWindowToSpace` returns false, and logs `err.verify` on the SLS-fallback branch.
- [ ] DW-5.5 (#48): all-cells-locked autoflow logs `warn.assign.dropped{wids}` (and/or falls back) instead of silently dropping windows.

**Difficulty:** MEDIUM
**Uncertainty:** #16's success-check seam is shared with P4 — ensure a single fix, not two.

---

### Phase 6: Borders
**Model:** sonnet
**Skills:** cc-defensive-programming, gof-design-patterns
**Gate:** Standard

**Goal:** Border state always derives from grid + focus state, with no off-main-queue reads.

**Scope:**
- IN: atomic-branch membership diff → rebuild; eliminate off-main reads; retarget success + reacquire; resize-redraw visibility repair; async `borders.query`; prune `windowOrderPerDisplay` on destroy. Findings #9 #27 #53 #54 #55 #56.
- OUT: focus authority (consumed from P3).

**Constraints:** `SimpleBorderManager` is `@unchecked Sendable` with the invariant "mutable state on `DispatchQueue.main`" — capture immutable locals BEFORE spawning `Task{}` (as `destroyAllBorders` already does), or make the class `@MainActor`. Border ops stay on main (§8).
**Edge cases:** atomic branch with cell+focus unchanged but membership changed (#9 — the silent-drop case); `Task{}` log block reading `freePool`/`activeBorder`/`focusedWindowID` off-main (#27); retarget to a destroyed window (#53 — bounds guard fails after committing targetID); `SLWindowContextCreate` failing on resize redraw (#54 — alpha 0, isVisible true); `borders.query` `main.sync` from the socket thread (#55).
**File hints:** `Borders/SimpleBorderManager.swift:147,165-189,346-376,479-492,585,676-685`; `Borders/BorderWindow.swift:325-417,442-463`.

**Depends on:** P1 (events reach borders via the serialized path), P3 (`GridState.focusedWindow` write-on-success invariant — the authoritative border target) | **Unlocks:** none (leaf)
**Produces:**
- Atomic `setCellAssignments` branch **diffs active-cell membership** and rebuilds when it changed (no silently-dropped delta).
- Off-main reads eliminated — immutable locals captured **before** spawning `Task {}` log blocks (or `@MainActor`).
- `retarget` returns success; the manager reacquires/hides on failure (no border stuck on a dead window).
- Resize-redraw failure repairs visibility (`isVisible=false` on failed redraw, or retry).
- `borders.query` async (no `DispatchQueue.main.sync` from the socket thread); `windowOrderPerDisplay` pruned on destroy.

**Done when:**
- [ ] DW-6.1 (#9): atomic `setCellAssignments` diffs active-cell membership and rebuilds on change — border added/removed correctly on a cell send; stack count correct (no silent delta drop).
- [ ] DW-6.2 (#27): all mutable state captured into immutable locals before any `Task{}` log block (or class made `@MainActor`) — no off-main reads of `freePool`/`activeBorder`/`focusedWindowID`.
- [ ] DW-6.3 (#53): `retarget` returns success; on a bounds-guard failure the manager hides/reacquires — no border stuck on a closed window.
- [ ] DW-6.4 (#54): a resize-redraw failure sets `isVisible=false` (or retries) so the next update repairs it; `err.bdr.resize_ctx` logged.
- [ ] DW-6.5 (#55): `borders.query` is async (continuation + `main.async`) — no client-thread `main.sync` hang.
- [ ] DW-6.6 (#56): `windowOrderPerDisplay` pruned on destroy — stack indicator count correct after a close.

**Difficulty:** MEDIUM
**Uncertainty:** None significant — localized to the borders subsystem.

---

### Phase 7: Silent errors, crash safety & infra
**Model:** opus
**Skills:** cc-defensive-programming, aposd-simplifying-complexity
**Gate:** Full

**Goal:** Make failures surface as errors + logs instead of being swallowed; keep the server alive across client disconnects; close ingress/socket/startup races.

**Scope:**
- IN: SIGPIPE survival; AX/CG/SLS/MSS return-code propagation; per-socket serialized full writes; startup ordering (handlers before accept, load before wiring); BFD watcher re-arm + concurrent pipe read + bundle-id match; AX messaging timeout; MSS wake re-probe; terminal show hard-fail; notify action dispatch; layout-cycle wipe deferral. Findings #1 #22 #33 #34 #36 #37 #38 #39 #44 #45 #46 #47 #49 #58.
- OUT: focus/border/space return-code paths fixed in their own phases.

**Constraints:** Robustness domain (consumer tool) — log-and-continue / surface, not crash; EXCEPT the SIGPIPE fix, which is correctness (the server must not die). Follow `jlog` error conventions; no `DispatchQueue.main.sync` from the actor (#44 → `await MainActor.run`).
**Edge cases:** client disconnect between request and reply (#1 EPIPE not SIGPIPE); short socket write (#46); handler dict written after accept (#49 startup-404 window); atomic-rename config save (#37); >64KB hotkey output (#38 pipe deadlock); off-screen terminal after AX fail (#39); permanent MSS cache after Dock restart (#36); blacklist by localizedName vs bundle id (#47); layout-cycle wipe before a throwing apply (#58).
**Approach notes:** Mostly independent one-file fixes — buildable as parallel sub-steps. `@notify` (#22) needs `handleNotify` to switch on `cmd.action` + `buildCommand` to forward payload.
**File hints:** `SocketServer.swift:33,233-254`; `CrashReporter.swift:78`; `MessageHandler.swift:26,1153,1407,1907-1962`; `main.swift:122,140-143,229`; `WindowManipulator.swift:458-497`; `MSSClient.swift:106-154,206`; `BFD/BFDManager.swift:162-194`; `BFD/BFDExecutor.swift:30-64`; `BFD/BFDKeyHandler.swift:244-255`; `Grid/GridTerminalManager.swift:181-222`; `Grid/GridCommandRouter.swift:399-410,880-930`; `StateManager.swift:1196-1230,1356,2058-2078`.

**Depends on:** P1 (loosely — the dispatch/handler-touching items) | **Unlocks:** none (leaf)
**Produces:**
- `SO_NOSIGPIPE` on accepted sockets + SIGPIPE removed from `CrashReporter`'s fatal list (server survives client disconnect).
- AX/CG/SLS/MSS return codes checked and logged at call sites (WindowManipulator, MSSClient, terminal show).
- Per-socket serialized writes + full-write loop (no interleaved/short JSONL frames).
- Handlers registered before `socketServer.start()`; `GridState.load()` awaited before wiring.
- BFD config watcher re-arms on atomic-rename + reads pipes concurrently; blacklist/overrides match bundle ID; `@notify` actions dispatched (not collapsed to toggle); MSS re-probe on wake; layout-cycle wipe deferred into `applyLayoutBody`.

**Security-sensitive:** yes — the UNIX socket is a trust boundary; this phase touches request-param handling and the write path. Validate framing/params (low risk: local user-owned socket).

**Done when:**
- [ ] DW-7.1 (#1): accepted sockets set `SO_NOSIGPIPE` + SIGPIPE removed from `CrashReporter`'s fatal list; a client disconnect mid-reply yields EPIPE handled by `sock.err` and the server stays up (test: kill client between request and reply).
- [ ] DW-7.2 (#46): per-socket serialized writes + full-write loop — no interleaved or short JSONL frames under event load.
- [ ] DW-7.3 (#49): all handlers registered before `socketServer.start()` (or the dict guarded) — no startup "method not found".
- [ ] DW-7.4 (#45): `GridState.load()` awaited before wiring — no clobber of early in-memory state.
- [ ] DW-7.5 (#44): `removeObserver` uses `await MainActor.run` (no actor-thread `main.sync`).
- [ ] DW-7.6 (#33): observer registration reserves the dict slot synchronously; a replaced observer is stopped — no duplicate AXObservers after wake.
- [ ] DW-7.7 (#34): `AXUIElementSetMessagingTimeout` set on app elements — no multi-second freeze on a beachballing app.
- [ ] DW-7.8 (#36): MSS `resetAvailabilityCache()` called on wake; re-probe on repeated `mss.fail`.
- [ ] DW-7.9 (#37): the BFD watcher re-arms on atomic-rename + logs `open` failure — a second config save applies.
- [ ] DW-7.10 (#38): BFD reads both pipes concurrently with the wait — a verbose command does not deadlock or false-timeout.
- [ ] DW-7.11 (#39): terminal `show()` treats AX-element-nil / `setWindowFrame`-false as a hard failure (no stranded off-screen window) and refuses to persist a sentinel frame.
- [ ] DW-7.12 (#47): BFD blacklist/overrides match `bundleIdentifier` — documented bundle-id config matches.
- [ ] DW-7.13 (#22): `@notify` dispatches on `cmd.action` + forwards payload — show/hide/push/dismiss behave correctly (not all collapsed to toggle).
- [ ] DW-7.14 (#58): the layout-cycle state wipe is deferred into `applyLayoutBody` — a thrown apply no longer leaves the space wiped.

**Difficulty:** MEDIUM
**Uncertainty:** Largest, most independent phase; can split into its own PR if it slows UAT.

---

## Test Coverage
**Level:** Backend 100% — every done-when item has a test. Tags: `[U]` pure-logic unit, `[I]` integration against faked `Ports/` protocols, `[M]` manual/UAT log-signature (the inherently-live concurrency items — driven on a deployed build, asserted via the named `jlog` signature), `[D]` dirty (error/boundary). Suspected findings are verified by `[M]` confirm-or-drop during UAT. Most fixes are error-path/guard fixes, so the suite is dirty-heavy by nature (≈5:1).

## Test Plan

**Phase 1 — Serialization foundation**
- `[U][D]` DW-1.3 fence refcount: acquire×2/release×1 still fenced; release of an unheld wid is a no-op; expiry path.
- `[U]` DW-1.7 generation counter increments per action, monotonic.
- `[U][D]` DW-1.5 nudge-repeat coalescing: N same-dir steps apply in order; out-of-order submit rejected.
- `[I]` DW-1.1 4 overlapping submits to the executor complete in submission order (fake router records order); `[M]` `cmd.exec{inflight}`≤1 under a held-key burst.
- `[I][D]` DW-1.2 two concurrent `layout cycle` submits → one consistent layout id+cell map (no `cellNotFoundInLayout`).
- `[I][D]` DW-1.4 concurrent double `@nudge enter` → ≤1 tap, token consumed once, exit leaves `suppressionDepth==0`; `[M]` `nudge.tap.installed/stopped` balanced.
- `[I][D]` DW-1.6 windowCreated/Destroyed during suppression queued + replayed at depth 0; replay of an already-gone wid is idempotent; `[M]` `reconcile.suppressed.queue/replay`.

**Phase 2 — Space & wake migration**
- `[U]` DW-2.1 reassignment gate predicate (old id absent ⇒ reassign, else activate); `[U]` DW-2.2 numeric sort + significant-state overwrite guard; `[U][D]` DW-2.6 zero/degenerate-bounds guard returns skip; `[U][D]` DW-2.2 count-mismatched old/new lists → partial+log.
- `[I][D]` DW-2.3 mid-apply migration → apply re-resolves/aborts (no zombie write); `[I]` DW-2.4 queued reset/resize after switch re-resolves space.
- `[M]` DW-2.1 two laid-out desktops on one display survive A→B→A (no `state.space_migrated.live` on persistent round-trip); `[M][D]` DW-2.5 login-screen wake keeps tiled windows (no `ax_orphan` while locked); `[M]` DW-2.7 resolution/Dock change reapplies; DW-2.8 borders resync after switch.
- `[M]` DW-2.9 `dsp.geometry.change` + display-join trace observed → #62s/#63s confirmed or dropped.

**Phase 3 — Focus ownership & navigation**
- `[U]` DW-3.3 skip-empty-cell selection predicate (clean + all-empty + wrap); `[U][D]` DW-3.7 detector trips on 3-window rotation + nil-actual; `[U]` DW-3.1 focusWindow returns false on a faked AX/CG failure.
- `[I][D]` DW-3.2 stale-cache scenario → no double-raise (fake StateProvider); `[I]` DW-3.4 focusSweep skips a fenced wid / stale generation; `[I][D]` DW-3.8 prune-before-setFocus ordering picks correct successor; `[I]` DW-3.9 minimize on a non-focused-display space frees the right slot.
- `[M]` DW-3.5 no focus inversion while typing; `[M][D]` DW-3.6 TSan clean on detector under concurrent focus; `[M]` DW-3.10 `win.focus.restore.skip` → #59s confirmed/dropped.

**Phase 4 — Creation, classification & adoption**
- `[U][D]` DW-4.1 `shouldUseSoleWindowFallback` truth table (resolvable-different ⇒ no-substitute; unresolvable ⇒ substitute); `[U]` DW-4.6 not_standard grace re-eval predicate.
- `[I][D]` DW-4.2 event+sweep cannot both consume one pending target (consume-before-await); `[I][D]` DW-4.3 pid-less target rejects a foreign window, bundle-id match accepts; failed launch clears+logs; `[I]` DW-4.4 locked cell on inactive space moves/defers; `[I][D]` DW-4.5 observer-register failure retries with backoff; `[I][D]` DW-4.7 in-flight apply merges (not clobbers) a pending claim; `[I]` DW-4.8 unassigned tileable logged+adopted at depth 0.
- `[M]` DW-4.9 `warn.space.derive_override` / poll-readd tombstone / subrole-requery traces → #29s/#60s/#61s confirmed or dropped.

**Phase 5 — Geometry writes**
- `[U][D]` DW-5.1 resize delta sign across stack positions incl. last (boundary: idx 0, mid, last, sole); `[U][D]` DW-5.2 split recalculate-not-equalize on add/remove (custom ratios preserved); `[U][D]` DW-5.5 all-cells-locked autoflow logs drop.
- `[I]` DW-5.3 displaced migration repositions target+source; `[I][D]` DW-5.4 move aborts state mutation on `moveWindowToSpace==false` + `err.verify` on SLS branch.

**Phase 6 — Borders**
- `[U][D]` DW-6.1 active-cell membership diff triggers rebuild (added/removed/unchanged); `[U]` DW-6.6 windowOrder pruned on destroy → correct count.
- `[I][D]` DW-6.3 retarget to a destroyed window returns failure → reacquire/hide; `[I][D]` DW-6.4 resize-redraw failure sets isVisible=false → next update repairs; `[I]` DW-6.5 `borders.query` async returns without main.sync.
- `[M][D]` DW-6.2 TSan clean on border churn (no off-main reads); `[M]` border follows a cell-send correctly.

**Phase 7 — Silent errors, crash safety & infra**
- `[U][D]` DW-7.12 bundle-id match predicate; `[U]` DW-7.13 notify action→command mapping (show/hide/push/dismiss distinct); `[U][D]` DW-7.2 full-write loop handles a short write.
- `[I][D]` DW-7.11 terminal show with faked AX-nil/setFrame-false aborts (no opacity/focus flip), refuses sentinel frame; `[I][D]` DW-7.6 duplicate observer registration reserves slot/stops replaced; `[I][D]` DW-7.10 BFD >64KB output doesn't deadlock; `[I]` DW-7.3 unknown method before full registration; `[I]` DW-7.14 thrown apply after cycle no longer wipes the space.
- `[M][D]` DW-7.1 kill client between request+reply → server survives (`sock.err`, no `srv.fatal SIGPIPE`); `[M]` DW-7.4 restart with early window keeps it; `[M]` DW-7.5 no stall on app-quit; `[M]` DW-7.7 no freeze on a beachballing app; `[M]` DW-7.8 MSS recovers after Dock restart; `[M]` DW-7.9 second `bfd.yaml` save applies.

---

## Assumptions
| Assumption | Confidence | Verify Before Phase | Fallback If Wrong |
|---|---|---|---|
| A serial command executor won't starve under normal hotkey rates (only wake-gated dispatch is long) | High | P1 | Add a read-only concurrency lane for query commands |
| The `Ports/` protocols (WindowController/StateProvider/BorderRendering/GridStorage) are fakeable for `[I]` tests | High | P1 | Characterization tests via real adapters + lean on `[M]` UAT |
| Lock state is observable via `com.apple.screenIsLocked/Unlocked` (DistributedNotificationCenter, already used) | High | P2 | Infer lock from auth/idle state; defer validator resume a fixed delay |
| `shouldUseSoleWindowFallback(resolved:soleWindowID:queriedID:)` (commit 1cf354e) is reusable as-is in WindowManipulator | High | P4 | Extract the helper to a shared location |
| The 6 suspected findings are reproducible during UAT to confirm/drop | Medium | owning phase UAT | Keep the instrumentation, leave the fix out, document as unconfirmed |
| `SO_NOSIGPIPE` is settable on the accepted UNIX-domain sockets on macOS | High | P7 | `signal(SIGPIPE, SIG_IGN)` process-wide |
| `AXUIElementSetMessagingTimeout` bounds blocking AX IPC effectively | High | P7 | Move AX property queries off-actor and apply results in a second hop |

## Decision Log
| Decision | Alternatives Considered | Rationale | Phase |
|---|---|---|---|
| Approach B — serial command executor | A actorize router+reconciler; C unified command+event mailbox | Smallest blast radius, strongest command-vs-command guarantee, lowest live-WM risk; residual TOCTOU needs the same fences under any approach | P1 (all) |
| Cluster-phases referencing the audit JSON as per-finding spec | One-finding-per-phase; split into multiple plans | 7-phase cap vs 63 findings; the saved audit doc carries the full mechanism per `#ID` | All |
| Suspected findings: instrument-then-confirm-in-UAT | Fix blind; defer out of plan | Audit constraint "a race you can't trace is suspected, not a fix" + user's UAT note | P2,P3,P4 |
| Backend 100% coverage | Project's minimal-targeted (3-5/feature); none | User override; `Ports/` fakes make it achievable; live items still need the `[M]` UAT layer | All |
| Load-bearing instrumentation folded per-fix | Separate logging-only phase | User note — each fix ships the log signature that proves it | All |

---

## Notes
- **Build P1 first and ship + UAT it before P2–P7.** It de-risks every dependent phase and proves the serial-executor seam on the live WM.
- **P2 (11) and P7 (14) are dense.** Either can be carved into its own PR if UAT cadence slows — flagged at the skeleton checkpoint, accepted as one plan.
- **TOCTOU findings (#13, #17, #42, #51) live in P2/P3, not P1** — they consume P1's fence + generation counter but each needs its own guard; do not expect P1 alone to close them.
- **#16's `moveWindowToSpace`-success seam is shared by P4 and P5** — implement once (P5 owns the geometry abort; P4 references it).
- **Per-finding spec:** `.local/state/audit/bug-inventory-2026-06-11.json` — the build agent reads the entry for each `#ID` (full mechanism, exact file:line, evidence, log signature, verifier rationale).
- **#2 multi-desktop data loss is mechanically certain but unobserved here** (this machine runs one tiled space per display) — UAT must set up two laid-out desktops on one display to confirm the fix.
- **Deploy + verify per `CLAUDE.md`:** `make run`; confirm restart via `ps -o lstart=`, `thegrid ping`, and `grep '"ev":"srv.start"'` on the server log; UAT log signatures live in `~/.local/state/thegrid/thegrid-server.json`.
- **Concurrency DW items (#3, #27, #35)** should additionally run under TSan; prefer extracting pure decision predicates (per `docs/code-standards.md` testing pattern) so the logic is unit-testable off the AX/SkyLight boundary.

---

## Execution Log

### Phase 1: Serialization foundation (Gate: Full)
- [x] BUILD: Discovery + design + TDD implementation complete
- [x] REVIEW: Verification passed (all 7 DW + 4 edge cases + 4 constraints, 131/131 suite)
- [x] Committed
Commit: 1b68a36
Summary: Shipped the serial `CommandExecutor` (AsyncStream + single consumer; MessageHandler/BFD submit through it) and four reconciler primitives — `RefcountedFence`, `GenerationCounter` (monotonic `generation` bumped per action), `SuppressedEventQueue` (windowCreated/Destroyed queued+replayed at depth 0), consume-once `ActionToken` — plus a serial nudge-step pump. Fixed #3 #4 #5 #11 #12 #14 #50. The four primitives + `CommandRunning`/`CommandExecutor` seam are the contract P2–P7 consume; reconciler stays a class (Approach B). Build clean, 131 tests green.
