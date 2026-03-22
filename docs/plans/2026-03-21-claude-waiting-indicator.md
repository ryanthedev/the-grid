# Plan: Claude Waiting Indicator in Picker

**Created:** 2026-03-21
**Status:** ready
**Complexity:** simple

---

## Context

When Claude Code is waiting for user input (AskUserQuestion), there's no way to know which terminal needs attention. The picker should show waiting windows at the top with a visual marker.

## Constraints

- Must work across multiple concurrent Claude Code sessions
- Signal via tmux pane user option (no file I/O, instant)
- Picker enrichment reads the signal and boosts priority
- Hook cleanup must be reliable (PostToolUse fires after user answers)

---

## Implementation Phases

### Phase 1: Hook + Signal
**Model:** sonnet

**Goal:** Add Claude Code hooks that set/clear a tmux pane option when AskUserQuestion is active.

**Scope:**
- IN: `PreToolUse` hook on `AskUserQuestion` that runs `tmux set-option -p @claude-waiting 1`, `PostToolUse` hook on `AskUserQuestion` that runs `tmux set-option -pu @claude-waiting`, add to `~/.claude/settings.json`
- OUT: Picker changes (Phase 2)

**Done when:**
- [ ] `tmux show-options -p @claude-waiting` returns `1` when Claude is waiting
- [ ] Option clears after user answers

---

### Phase 2: Picker Awareness
**Model:** sonnet

**Goal:** Picker detects `@claude-waiting` on tmux panes and boosts those windows to the top with a visual marker.

**Scope:**
- IN: TmuxEnricher queries `@claude-waiting` pane option during refresh, passes flag through EnrichmentResult, WindowSource sets priority 2000+ and prepends marker to title for waiting windows
- OUT: Hook configuration (Phase 1)

**File hints:**
- `grid-server/Sources/GridServer/Picker/Enrichment/TmuxEnricher.swift` -- query pane options
- `grid-server/Sources/GridServer/Picker/Enrichment/EnrichmentTypes.swift` -- add waiting flag
- `grid-server/Sources/GridServer/Picker/WindowSource.swift` -- priority boost + title marker

**Done when:**
- [ ] Waiting windows appear above all other windows in picker
- [ ] Waiting windows show visual marker in title
- [ ] Non-waiting windows unaffected

---

## Test Coverage

**Level:** None (manual verification)

## Test Plan

- [ ] Manual: Open Claude Code, trigger AskUserQuestion, verify `@claude-waiting` is set
- [ ] Manual: Answer question, verify `@claude-waiting` is cleared
- [ ] Manual: Open picker, verify waiting window appears first with marker

---

## Notes

- TmuxEnricher already runs `tmux list-clients` during refresh -- adding a pane option query is minimal overhead
- Priority 2000 puts waiting windows above normal windows (1000) and all other sources

---

## Execution Log

_To be filled during /code-foundations:building_
