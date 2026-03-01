package edit

import (
	"fmt"
	"strconv"
	"strings"
)

// FormatWindowLine formats a window entry for the edit buffer.
// Format: "67842  Firefox — GitHub - PR #45" or "67842  Firefox — GitHub - PR #45 (2 tabs)"
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

// ParseWindowLine extracts the window ID from the start of a line.
// Everything after the ID is display-only and ignored.
func ParseWindowLine(line string) (uint32, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return 0, fmt.Errorf("empty line")
	}

	// Extract first whitespace-delimited token
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return 0, fmt.Errorf("empty line")
	}

	id, err := strconv.ParseUint(fields[0], 10, 32)
	if err != nil {
		return 0, fmt.Errorf("invalid window ID %q: %w", fields[0], err)
	}

	return uint32(id), nil
}

// FormatCellHeader formats a cell section header.
// Format: "# cell: main"
func FormatCellHeader(cellID string) string {
	return fmt.Sprintf("# cell: %s", cellID)
}

// ParseCellHeader checks if a line is a cell header and extracts the cell ID.
// Returns the cell ID and true if the line is a header, or ("", false) otherwise.
func ParseCellHeader(line string) (string, bool) {
	line = strings.TrimSpace(line)
	prefix := "# cell: "
	if strings.HasPrefix(line, prefix) {
		cellID := strings.TrimSpace(line[len(prefix):])
		if cellID != "" {
			return cellID, true
		}
	}
	return "", false
}
