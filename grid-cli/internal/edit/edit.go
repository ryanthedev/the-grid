package edit

import (
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// CellInfo describes a cell and its windows for buffer building.
type CellInfo struct {
	CellID  string
	Windows []WindowEntry
}

// WindowEntry describes a window for display in the edit buffer.
type WindowEntry struct {
	WID     uint32
	AppName string
	Title   string
}

// EditResult describes the changes detected after editing.
type EditResult struct {
	// New window ordering per cell (only cells that changed)
	CellWindows map[string][]uint32
	// Windows to close (present in original but not in edited)
	CloseWindows []uint32
	// Whether anything changed
	Changed bool
}

// BuildBuffer generates the edit buffer text for a single cell.
func BuildBuffer(cell CellInfo) string {
	var b strings.Builder
	b.WriteString("# thegrid layout edit — reorder windows by moving lines\n")
	b.WriteString("# Delete a line to close the window. Save and quit to apply.\n")
	b.WriteString("# Lines starting with # are ignored. Do not edit window IDs.\n")
	b.WriteString("#\n")

	for _, w := range cell.Windows {
		b.WriteString(FormatWindowLine(w.WID, w.AppName, w.Title))
		b.WriteString("\n")
	}

	return b.String()
}

// BuildBufferAll generates the edit buffer text for all cells.
// Cells should be passed in visual order (sorted by position).
func BuildBufferAll(cells []CellInfo) string {
	var b strings.Builder
	b.WriteString("# thegrid layout edit --all — reorganize windows across cells\n")
	b.WriteString("# Move lines between sections to move windows. Delete to close.\n")
	b.WriteString("# Lines starting with # are ignored. Do not edit window IDs.\n")

	for _, cell := range cells {
		b.WriteString("\n")
		b.WriteString(FormatCellHeader(cell.CellID))
		b.WriteString("\n")
		for _, w := range cell.Windows {
			b.WriteString(FormatWindowLine(w.WID, w.AppName, w.Title))
			b.WriteString("\n")
		}
	}

	return b.String()
}

// ParseBufferSingle parses the edited buffer for a single-cell edit.
// Returns the new window order for that cell.
func ParseBufferSingle(content string, cellID string) (map[string][]uint32, error) {
	var windows []uint32
	seen := make(map[uint32]bool)

	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		wid, err := ParseWindowLine(line)
		if err != nil {
			continue
		}

		if !seen[wid] {
			seen[wid] = true
			windows = append(windows, wid)
		}
	}

	return map[string][]uint32{cellID: windows}, nil
}

// ParseBufferAll parses the edited buffer for an all-cells edit.
// Returns the new window assignments per cell.
func ParseBufferAll(content string) (map[string][]uint32, error) {
	result := make(map[string][]uint32)
	seen := make(map[uint32]bool)
	currentCell := ""

	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		// Check for cell header before general comment skip
		if cellID, ok := ParseCellHeader(line); ok {
			currentCell = cellID
			if _, exists := result[currentCell]; !exists {
				result[currentCell] = []uint32{}
			}
			continue
		}

		if strings.HasPrefix(line, "#") {
			continue
		}

		if currentCell == "" {
			continue
		}

		wid, err := ParseWindowLine(line)
		if err != nil {
			continue
		}

		if !seen[wid] {
			seen[wid] = true
			result[currentCell] = append(result[currentCell], wid)
		}
	}

	return result, nil
}

// DiffChanges compares original and edited window assignments to produce an EditResult.
func DiffChanges(original, edited map[string][]uint32) EditResult {
	result := EditResult{
		CellWindows: edited,
	}

	// Build flat wid→cellID map for original
	originalWids := make(map[uint32]string)
	for cellID, wids := range original {
		for _, wid := range wids {
			originalWids[wid] = cellID
		}
	}

	// Build flat wid→cellID map for edited
	editedWids := make(map[uint32]string)
	for cellID, wids := range edited {
		for _, wid := range wids {
			editedWids[wid] = cellID
		}
	}

	// Windows in original but not in edited → close
	for wid := range originalWids {
		if _, exists := editedWids[wid]; !exists {
			result.CloseWindows = append(result.CloseWindows, wid)
		}
	}

	// Check if anything changed
	if len(result.CloseWindows) > 0 {
		result.Changed = true
	} else {
		// Check for reorders or cross-cell moves
		for cellID, editedWids := range edited {
			origWids, ok := original[cellID]
			if !ok || len(origWids) != len(editedWids) {
				result.Changed = true
				break
			}
			for i, wid := range editedWids {
				if origWids[i] != wid {
					result.Changed = true
					break
				}
			}
			if result.Changed {
				break
			}
		}
		// Also check if cells were removed
		if !result.Changed {
			for cellID := range original {
				if _, ok := edited[cellID]; !ok {
					result.Changed = true
					break
				}
			}
		}
	}

	return result
}

// OpenEditor opens the given file in the user's preferred editor.
// Returns nil on success (exit code 0), error otherwise.
func OpenEditor(filePath string) error {
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = os.Getenv("VISUAL")
	}
	if editor == "" {
		editor = "vi"
	}

	cmd := exec.Command(editor, filePath)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	return cmd.Run()
}

// HashContent returns the SHA256 hash of content for change detection.
func HashContent(content []byte) [32]byte {
	return sha256.Sum256(content)
}

// OriginalAssignments extracts the original window assignments from CellInfo slices.
func OriginalAssignments(cells []CellInfo) map[string][]uint32 {
	result := make(map[string][]uint32)
	for _, cell := range cells {
		wids := make([]uint32, len(cell.Windows))
		for i, w := range cell.Windows {
			wids[i] = w.WID
		}
		result[cell.CellID] = wids
	}
	return result
}

// WriteTempFile writes content to a temp file and returns its path.
// Caller is responsible for removing the file.
func WriteTempFile(content string) (string, error) {
	f, err := os.CreateTemp("", "thegrid-edit-*.txt")
	if err != nil {
		return "", fmt.Errorf("failed to create temp file: %w", err)
	}

	if _, err := f.WriteString(content); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", fmt.Errorf("failed to write temp file: %w", err)
	}

	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return "", fmt.Errorf("failed to close temp file: %w", err)
	}

	return f.Name(), nil
}
