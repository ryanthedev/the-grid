# Plan: Notification Panel Audit Fixes

**Created:** 2026-03-22
**Status:** ready
**Complexity:** simple

---

## Context

Fix all 17 findings from the notification panel sanity audit. Findings span concurrency races (CONC-2, CONC-3), input injection (LOGIC-11), unchecked returns (ERR-3), force-unwraps (NULL-2), silent error swallowing (ERR-8), incomplete read drains (NULL-6), weak tests (LOGIC-11), and minor validation gaps. Each fix is surgical -- no new features, no refactoring beyond what each finding requires. This is a fix-up pass on the existing feature/notification-panel branch.

## Constraints

- All changes on existing feature/notification-panel worktree branch
- Direct implementation with POST-GATE verification (no PRE-GATE)
- Build must pass, existing 20 tests must still pass
- Fix only what the audit flagged -- no scope creep

---

## Implementation Phases

### Phase 1: Fix HIGH-severity findings
**Model:** sonnet
**Pipeline:** direct

**Goal:** Fix the 5 HIGH-severity findings that pose crash, injection, or correctness risks.

**Scope:**
- IN: Finding #1 (ViewModel refresh race — CONC-3), #2 (RPC flag injection — LOGIC-11), #3 (FileWatcher isRunning race — CONC-2), #4 (fstat unchecked — ERR-3), #5 (hot-reload TOCTOU — CONC-3)
- OUT: All MEDIUM and LOW findings

**Done when:**
- [ ] ViewModel `refreshNotifications()` cancels in-flight Task before starting new one (private refreshTask property)
- [ ] RPC handlers for `list`, `dismiss`, `clear` bypass command string serialization (call store directly like `push` does) or validate inputs contain no whitespace/flags
- [ ] `NotificationFileWatcher.start()` guards `isRunning` check+set within its serial queue
- [ ] `fstat()` return value checked; on failure, log error, tearDown, and schedule retry
- [ ] Hot-reload event handler replacement prevents duplicate handlers (stop old before creating new, or serialize with a flag)
- [ ] Build passes, all 20 existing tests pass

---

### Phase 2: Fix MEDIUM + LOW findings
**Model:** sonnet
**Pipeline:** direct

**Goal:** Fix remaining 12 findings covering force-unwraps, silent errors, incomplete reads, validation gaps, and weak tests.

**Scope:**
- IN: Findings #6-#17
- OUT: Nothing -- final phase

**Done when:**
- [ ] RPC push handler uses consistent store reference (injected or documented as same singleton)
- [ ] `bulkDismiss/bulkPin` visual select: exitVisualSelect called after async work, or refresh race addressed by Phase 1 fix
- [ ] `runShellCommand`: `try?` replaced with do/catch, jlog only on success, error logged on failure
- [ ] `NSScreen.screens.first!` replaced with safe guard/fallback
- [ ] FileWatcher `handleReadable` loops `read()` until bytesRead <= 0 (drain all available data per event)
- [ ] `testPersistenceEmptyStore` adds+removes a notification before flush to actually dirty the store and exercise file round-trip
- [ ] Empty `exec:`/`url:` action payloads rejected (guard !payload.isEmpty)
- [ ] Stale `.tmp` file removed in catch block after rename failure
- [ ] `NotifyCount` prints "0" or error message when server response is unexpected
- [ ] Unknown action types in FileWatcher logged with warning
- [ ] `isVisible = true` moved after `makeKeyAndOrderFront`
- [ ] Bare `=` and `_` key handling: comment added documenting intentional no-op, or keys forwarded
- [ ] Build passes, all tests pass (including updated empty store test)

---

## Test Coverage

**Level:** Backend only

## Test Plan

- [ ] Existing 20 NotificationStore tests still pass
- [ ] Updated `testPersistenceEmptyStore` exercises actual file round-trip
- [ ] Manual: `thegrid notify push` with multi-word values, `thegrid notify list`, `thegrid notify toggle`

---

## Notes

- The audit findings reference is the review output from 4 parallel audit agents run earlier in this conversation
- Finding #7 (bulkDismiss/bulkPin TOCTOU) is a secondary instance of #1 -- fixing #1's refresh serialization also fixes #7
- Finding #6 (store divergence) may be a false positive if NotificationStore.shared IS the same object passed to GridCommandRouter -- but should be made explicit either way

---

## Execution Log

_To be filled during building_
