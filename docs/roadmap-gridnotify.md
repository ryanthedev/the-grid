# GridNotify Roadmap

## Immediate Wins
- **Contact name resolution** — Show "Sarah" instead of "+16463910068". macOS Contacts database queryable via Contacts.framework or SQLite at ~/Library/Application Support/AddressBook/
- **Group chat support** — 1:1 only right now. Group chats use a different handle structure in chat.db
- **Notification sounds** — Subtle sound on arrival, configurable per source

## Watch Directory
- **Drop-in directory** — `~/.local/state/thegrid/notify.d/` where any process drops `.json` files. Atomic writes, survives restarts, no pipe contention. Good for CI webhooks, cron jobs

## More Sources (new managed scripts)
- **GitHub** — PR reviews, CI failures, mentions. Poll GitHub API with PAT
- **Slack** — DMs/mentions via Slack webhook or RTM API
- **Calendar** — Upcoming meeting alerts from macOS Calendar.app (EventKit)
- **System alerts** — Disk space, battery, high CPU, process crashes

## UI Improvements
- **Notification categories/tabs** — Filter by source (iMessage, GitHub, system) with vim keys
- **Quick reply for iMessage** — Type reply in GridNotify, send via AppleScript
- **Rich detail views** — PR diffs in detail window, calendar events with join links
- **Notification rules engine** — YAML config for auto-dismiss, auto-pin, priority escalation based on patterns

## Architecture
- **Module system** — Pluggable notification types with configurable grouping, detail behavior, and animations per source
- **Notification history search** — Full-text search across all notifications with date ranges
- **Configurable grouping rules** — Cascade: individual → grouped by sender → super-grouped when too many. Each level configurable in YAML
