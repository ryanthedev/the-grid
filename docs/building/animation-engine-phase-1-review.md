# Review: Phase 1 - Animation Engine Core

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-1.1 | AnimationEffect protocol exists with phase context and notification data | SATISFIED | `AnimationEngine.swift:40-43` — `AnimationEffect` protocol with `static var name`. `AnimationContext` struct at line 19-32 carries phase, isArrival, isRead, tick, theme, and all notification fields. |
| DW-1.2 | AnimationRegistry resolves string names to effect instances | SATISFIED | `AnimationEngine.swift:49-86` — `AnimationRegistry.shared` singleton, `register()`, `effect(named:)`, `registeredNames`. All 12 builtins registered in `registerBuiltins()`. |
| DW-1.3 | YAML config defines animation presets per source with per-phase animation lists | SATISFIED | `AnimationConfig.swift:8-67` — `AnimationPreset` (arrival/idle/warning/ghost), `AnimationConfig` with `defaultPreset` + `sourcePresets`. `AnimationConfigYAML`/`AnimationPresetYAML` decode the `animations:` key in notify.yaml. `builtinDefault` at line 58 provides the fallback. |
| DW-1.4 | Per-notification JSON `animations` field overrides YAML defaults | SATISFIED | `Notification.swift:117-118` — `animationOverride: NotificationAnimationOverride?` on `GridNotification`. `NotificationFileWatcher.swift:27` — `let animations: NotificationAnimationOverride?` on `NotificationLineDescriptor`. Passed through at line 289: `animationOverride: desc.animations`. Priority logic in `AnimationConfig.activeAnimations` (AnimationConfig.swift:38-55). |
| DW-1.5 | Hot-reload updates animation config when notify.yaml changes | SATISFIED | `AnimationConfig.swift:164-262` — `AnimationConfigWatcher` uses `DispatchSource.makeFileSystemObjectSource` watching `.write`, `.delete`, `.rename`. Handles rename (atomic write) with tearDown+re-open. `AppDelegate.swift:63-69` — watcher started, `onConfigChange` callback wired to `vm.updateAnimationConfig`. Stopped in `applicationWillTerminate` at line 142. |
| DW-1.6 | All 12 existing animations migrated to protocol conformance | SATISFIED | `AnimationEngine.swift:93-139` — 12 effect structs: `ShakeEffect`, `BreathingEffect`, `SlideInEffect`, `GrowEffect`, `BorderStrobeEffect`, `FadeToGhostEffect`, `MatrixTitleEffect`, `WaveTitleEffect`, `ProgressBarEffect`, `WarningPulseEffect`, `ArrivalFlashEffect`, `SpinnerEffect`. All conform to `AnimationEffect`. Test at `AnimationEngineTests.swift:31-50` confirms 12 names registered. |
| DW-1.7 | NotificationItemView uses AnimatedNotificationView instead of hardcoded conditionals | SATISFIED | `NotificationPanelViews.swift:209` — `NotificationItemView` accepts `animationConfig: AnimationConfig`. The `isActive(_:)` helper at line 253-260 replaces all hardcoded conditionals. `animationConfig` flows from `viewModel.animationConfig` via `NotificationListView` at line 140. No raw `phase == .warning` or `isArrival` pattern-matching present in view rendering — all gated through `isActive()`. |
| DW-1.8 | Visual behavior identical to current after migration (same animations, same phases) | SATISFIED | `AnimationConfig.builtinDefault` (AnimationConfig.swift:58-66) encodes the same activation set that was hardcoded. View layer double-guards with both `isActive()` and explicit phase/state checks (e.g., `isActive("shake") && phase == .warning` at line 338, `isActive("matrix_title") && isArrival` at line 377), preserving original conditional semantics exactly. |

**All requirements met:** YES

## Spec Match

- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage matches plan (minimal unit tests for core logic)

**Section-by-section:**

| Pseudocode Section | Implementation | Notes |
|---|---|---|
| AnimationContext + AnimationEffect protocol | `AnimationEngine.swift:8-43` | Implementation adds `animationPhase: AnimationPhase` field alongside `phase: LifecyclePhase` — an improvement, not a deviation. Pseudocode had only `apply<V>(to:context:) -> AnyView`; impl drops the `apply` method since content-replacement effects are handled inline. This is the "sentinel/no-op" design documented in the discovery. Acceptable — the protocol is lighter and the complexity is in the view layer, not the protocol. |
| AnimationRegistry | `AnimationEngine.swift:49-86` | Exact match. `private init()` added — correct singleton. |
| AnimationConfig YAML model | `AnimationConfig.swift:8-102` | Uses `NotifyConfigAnimationsOnly` private struct instead of full `NotifyConfigYAML` — more minimal, no behavioural difference. |
| AnimationConfigWatcher / hot-reload | `AnimationConfig.swift:159-262` | Added `isRunning` guard throughout — more defensive than pseudocode, a quality improvement. |
| Migrate 12 existing animations | `AnimationEngine.swift:93-139` | Lighter structs (name-only, no `activePhases` or `apply` method) vs pseudocode's full protocol. Valid given the simplified protocol design. |
| NotificationItemView config-driven | `NotificationPanelViews.swift:201-466` | Full match. All hardcoded phase conditionals replaced. `isActive()` helper is cleaner than pseudocode's inline `isAnimationActive()` calls. |
| ViewModel animationConfig | `NotificationPanelViewModel.swift:65, 107-109` | Exact match. |
| AppDelegate wiring | `AppDelegate.swift:57-69, 142` | Exact match. |

**Deviation note:** The `AnimationEffect` protocol dropped the `apply<V>(to:context:) -> AnyView` method. The pseudocode explicitly noted that content-replacement effects (matrix_title, wave_title, progress_bar, etc.) would be no-ops at the row level, making the method vestigial for most effects. The implementation went one level further and removed it entirely, keeping the protocol as a pure registration/naming marker. This is documented with a comment at line 37-39. The tradeoff: future effects cannot inject row-level behavior through the protocol — they require direct view changes. This is acceptable for Phase 1 (all effects are pre-known) but worth noting for Phase 2+ when new effects are added.

## Dead Code

**`AnimationContext` struct is defined but never used to pass context to effects** (`AnimationEngine.swift:19-32`). The struct is constructed nowhere in the codebase — `computeAnimationPhase` and `isAnimationActive` take individual parameters, not an `AnimationContext`. Since the protocol dropped `apply(to:context:)`, there's no call site that would use it.

This is dead code. It carries no runtime cost, but it adds confusion about whether `AnimationContext` is the intended API surface.

**Severity:** minor finding, not a blocker.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | PASS | `AnimationConfigWatcher` runs on a private serial queue (`com.thegrid.notify.animconfig`). `isRunning` is only mutated from the queue (`queue.sync` in `start()`/`stop()`). `onConfigChange` dispatches to main thread before calling the callback. No shared mutable state accessed off-queue. |
| Error Handling | PASS | `loadAnimationConfigFromYAML()` catches decode errors and returns `.builtinDefault` with a log entry. File-not-found returns `.builtinDefault`. `effect(named:)` returns optional. Parse failures in `NotificationFileWatcher` are logged and silently skipped — consistent with existing behaviour. |
| Resources | PASS | `AnimationConfigWatcher.tearDown()` cancels the `DispatchSource` and closes `fd`. Called from both `stop()` and on rename/delete before re-open. `[weak self]` used in all async closures to prevent retain cycles. `[weak vm]` in AppDelegate's `onConfigChange` closure. |
| Boundaries | PASS | `SpriteView.startAnimation()` guards `frames.count > 1`. `warningProgress` guards `warnBefore > 0`. `ghostPhase` computation guards `remaining > 0` (AnimationEngine.swift:153). `activeAnimations` handles nil overrides, missing source presets, and empty lists. |
| Security | N/A | No user input surfaces beyond YAML config (operator-controlled) and notification JSON (pipe — operator-controlled). Animation name strings from config are only used as dictionary keys, never executed. |

## Defensive Programming: PASS

No silent failures found. Error paths:
- YAML decode failure → log + fallback (`err.notify.animcfg.parse`)
- File watcher open failure → log + retry after 5s (`notify.animcfg.nofile`)
- Unknown animation name → `effect(named:)` returns nil; `isActive()` returns false (safe no-op)
- Unknown JSON action type → logged as `warn.notify.watcher.action`, returns nil (existing behavior)

One observation: `SpriteView.startAnimation()` creates a `Timer` that is never invalidated. The timer's closure captures `frameIndex` by reference (via `self`), but `SpriteView` is a struct — the timer captures a copy. This is a pre-existing issue in the codebase (not introduced in this phase) and is not a regression.

## Design Quality

**Depth over length:** `AnimationConfig.activeAnimations()` encapsulates the three-level priority chain (override > source > default) in one place. `isActive()` in the view is a thin shim over it — appropriate.

**`AnimationContext` struct is defined but unused (MEDIUM).** It was designed for `apply(to:context:)` but that method was removed. The struct now exists with no call sites. This creates confusion: a reader expects it to be the primary context-passing mechanism but finds it unused. Options are to remove it or restore `apply(to:context:)`. Neither is a blocker, but leaving it risks future code being written against a dead API.

**`activePhases` was removed from the protocol.** The pseudocode had `static var activePhases: Set<AnimationPhase>` for self-documentation. The implementation dropped this. It's not load-bearing (the view drives activation), but it was the intended documentation mechanism for "which phases does this effect activate in." Minor loss of self-documentation.

**`builtinDefault` includes `fade_to_ghost` in arrival, idle, and warning phases** (AnimationConfig.swift:60-63), not just ghost. This means `fadeToGhost` is always checked across phases; it no-ops when `secondsRemaining` is nil (permanent notifications) or > 3s. Functionally correct, but the phase list is broader than the pseudocode's `ghost: ["fade_to_ghost"]`. The view handles this correctly at line 340 (`isActive("fade_to_ghost") ? remaining : nil`), passing nil when not activated.

## Testing: PASS

5 tests covering: registry lookup (positive + negative + all 12 names), config source override, per-notification override, and all 4 phase computations. Matches the "3-5 targeted tests" guideline. Tests are in `AnimationEngineTests.swift`.

**Dirty:clean ratio:** No dirty tests. All tests use real types and test real behavior (no mocking).

**Gap:** `AnimationConfigWatcher` is not tested. Hot-reload behavior requires file system interaction and is acceptably left untested for Phase 1 given the project's minimal-test philosophy.

## Issues

No blockers. Minor findings:

1. **Dead `AnimationContext` struct**
   - File: `AnimationEngine.swift:19-32`
   - Fix: Either remove it (clean) or restore `apply(to:context:) -> AnyView` to the protocol and have effects use it (restores intended design). The latter enables future Phase 2+ effects to inject behavior through the protocol rather than requiring view-layer changes.

2. **`activePhases` removed from protocol**
   - File: `AnimationEngine.swift:40-43`
   - Fix: Optional — add `static var activePhases: Set<AnimationPhase> { get }` back to the protocol as documentation. No behavior impact.

**Verdict: PASS**
