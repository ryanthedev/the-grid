# Phase 1 Discovery: Add subtitle to WindowEntry and FormatWindowLine

## WindowEntry Struct
**File:** `grid-cli/internal/edit/edit.go:18-22`
```go
type WindowEntry struct {
	WID     uint32
	AppName string
	Title   string
}
```
Needs: `Subtitle string` field

## FormatWindowLine
**File:** `grid-cli/internal/edit/format.go:11-16`
```go
func FormatWindowLine(wid uint32, appName, title string) string {
	if title != "" {
		return fmt.Sprintf("%d  %s — %s", wid, appName, title)
	}
	return fmt.Sprintf("%d  %s", wid, appName)
}
```
Needs: 4th `subtitle string` param, append ` (subtitle)` when non-empty

## Call Sites for FormatWindowLine (2)

1. `grid-cli/internal/edit/edit.go:43` — `BuildBuffer()`: `FormatWindowLine(w.WID, w.AppName, w.Title)`
2. `grid-cli/internal/edit/edit.go:63` — `BuildBufferAll()`: `FormatWindowLine(w.WID, w.AppName, w.Title)`

Both need `w.Subtitle` added as 4th arg.

## WindowEntry Construction Sites (2)

1. `grid-cli/cmd/grid/main.go:1608-1612` — `--all` branch
2. `grid-cli/cmd/grid/main.go:1628-1632` — focused-cell branch

Both currently set WID/AppName/Title only. Subtitle will be set in Phase 2 (enricher wiring).

## Test
**File:** `grid-cli/internal/edit/edit_test.go:7-16`
- `TestFormatAndParseWindowLine` calls `FormatWindowLine(67842, "Firefox", "GitHub - PR #45")`
- Needs update to test with subtitle (empty and non-empty cases)

## ParseWindowLine — No Change Needed
Only reads leading uint32 ID, ignores rest of line.
