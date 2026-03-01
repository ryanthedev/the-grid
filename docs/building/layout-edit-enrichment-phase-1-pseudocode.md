# Phase 1 Pseudocode: Add subtitle to WindowEntry and FormatWindowLine

## 1. Add `Subtitle string` to WindowEntry

**File:** `grid-cli/internal/edit/edit.go`, lines 18-22

```
// Before:
type WindowEntry struct {
    WID     uint32
    AppName string
    Title   string
}

// After:
type WindowEntry struct {
    WID      uint32
    AppName  string
    Title    string
    Subtitle string
}
```

No other fields change. Subtitle is optional; zero value "" means no subtitle.

---

## 2. Update FormatWindowLine signature and logic

**File:** `grid-cli/internal/edit/format.go`, lines 9-16

```
// Before:
func FormatWindowLine(wid uint32, appName, title string) string {
    if title != "" {
        return fmt.Sprintf("%d  %s — %s", wid, appName, title)
    }
    return fmt.Sprintf("%d  %s", wid, appName)
}

// After:
func FormatWindowLine(wid uint32, appName, title, subtitle string) string {
    var base string
    if title != "" {
        base = fmt.Sprintf("%d  %s — %s", wid, appName, title)
    } else {
        base = fmt.Sprintf("%d  %s", wid, appName)
    }
    if subtitle != "" {
        return base + " (" + subtitle + ")"
    }
    return base
}
```

Logic:
1. Build the base string exactly as before (wid + appName, optionally + title).
2. If subtitle is non-empty, append ` (subtitle)` to the base string.
3. Return.

Example outputs:
- `FormatWindowLine(67842, "Firefox", "GitHub - PR #45", "")` -> `"67842  Firefox — GitHub - PR #45"`
- `FormatWindowLine(67842, "Firefox", "GitHub - PR #45", "2 tabs")` -> `"67842  Firefox — GitHub - PR #45 (2 tabs)"`
- `FormatWindowLine(67842, "Firefox", "", "2 tabs")` -> `"67842  Firefox (2 tabs)"`

ParseWindowLine (lines 18-38) is unchanged -- it only reads the leading uint32.

---

## 3. Update BuildBuffer call site

**File:** `grid-cli/internal/edit/edit.go`, line 43

```
// Before:
b.WriteString(FormatWindowLine(w.WID, w.AppName, w.Title))

// After:
b.WriteString(FormatWindowLine(w.WID, w.AppName, w.Title, w.Subtitle))
```

---

## 4. Update BuildBufferAll call site

**File:** `grid-cli/internal/edit/edit.go`, line 63

```
// Before:
b.WriteString(FormatWindowLine(w.WID, w.AppName, w.Title))

// After:
b.WriteString(FormatWindowLine(w.WID, w.AppName, w.Title, w.Subtitle))
```

---

## 5. Update TestFormatAndParseWindowLine

**File:** `grid-cli/internal/edit/edit_test.go`, lines 7-16

```
// Before:
func TestFormatAndParseWindowLine(t *testing.T) {
    line := FormatWindowLine(67842, "Firefox", "GitHub - PR #45")
    wid, err := ParseWindowLine(line)
    if err != nil {
        t.Fatalf("ParseWindowLine failed: %v", err)
    }
    if wid != 67842 {
        t.Errorf("expected 67842, got %d", wid)
    }
}

// After:
func TestFormatAndParseWindowLine(t *testing.T) {
    // Case 1: no subtitle (empty string)
    line := FormatWindowLine(67842, "Firefox", "GitHub - PR #45", "")
    wid, err := ParseWindowLine(line)
    if err != nil {
        t.Fatalf("ParseWindowLine failed: %v", err)
    }
    if wid != 67842 {
        t.Errorf("expected 67842, got %d", wid)
    }
    if line != "67842  Firefox — GitHub - PR #45" {
        t.Errorf("unexpected line without subtitle: %q", line)
    }

    // Case 2: non-empty subtitle
    line2 := FormatWindowLine(67842, "Firefox", "GitHub - PR #45", "2 tabs")
    wid2, err := ParseWindowLine(line2)
    if err != nil {
        t.Fatalf("ParseWindowLine with subtitle failed: %v", err)
    }
    if wid2 != 67842 {
        t.Errorf("expected 67842, got %d", wid2)
    }
    if line2 != "67842  Firefox — GitHub - PR #45 (2 tabs)" {
        t.Errorf("unexpected line with subtitle: %q", line2)
    }
}
```

Tests validate:
- Empty subtitle produces identical output to the old behavior.
- Non-empty subtitle appends ` (subtitle)` after the base string.
- ParseWindowLine still extracts the correct WID in both cases.

---

## Summary of touched files

| File | Change |
|------|--------|
| `edit.go:21` | Add `Subtitle string` field to WindowEntry |
| `format.go:11` | Add 4th param `subtitle string` to FormatWindowLine |
| `format.go:12-16` | Append ` (subtitle)` when non-empty |
| `edit.go:43` | Pass `w.Subtitle` as 4th arg in BuildBuffer |
| `edit.go:63` | Pass `w.Subtitle` as 4th arg in BuildBufferAll |
| `edit_test.go:7-16` | Test empty and non-empty subtitle rendering + parse roundtrip |

No changes to ParseWindowLine, ParseCellHeader, or any other function.
