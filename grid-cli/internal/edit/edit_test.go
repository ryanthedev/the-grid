package edit

import (
	"testing"
)

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

func TestFormatAndParseCellHeader(t *testing.T) {
	header := FormatCellHeader("main")
	cellID, ok := ParseCellHeader(header)
	if !ok {
		t.Fatal("ParseCellHeader returned false")
	}
	if cellID != "main" {
		t.Errorf("expected 'main', got %q", cellID)
	}
}

func TestParseCellHeaderNotHeader(t *testing.T) {
	_, ok := ParseCellHeader("# just a comment")
	if ok {
		t.Error("expected false for non-header comment")
	}
}

func TestParseBufferSingle(t *testing.T) {
	buf := `# comment
67842  Firefox — GitHub
12903  Alacritty — nvim
`
	result, err := ParseBufferSingle(buf, "main")
	if err != nil {
		t.Fatal(err)
	}
	wids := result["main"]
	if len(wids) != 2 || wids[0] != 67842 || wids[1] != 12903 {
		t.Errorf("unexpected result: %v", wids)
	}
}

func TestParseBufferAll(t *testing.T) {
	buf := `# header comment

# cell: main
67842  Firefox — GitHub
12903  Alacritty — nvim

# cell: sidebar
45210  Slack — #general
`
	result, err := ParseBufferAll(buf)
	if err != nil {
		t.Fatal(err)
	}
	if len(result["main"]) != 2 {
		t.Errorf("main: expected 2 windows, got %d", len(result["main"]))
	}
	if len(result["sidebar"]) != 1 {
		t.Errorf("sidebar: expected 1 window, got %d", len(result["sidebar"]))
	}
}

func TestDiffChanges_Reorder(t *testing.T) {
	original := map[string][]uint32{"main": {1, 2, 3}}
	edited := map[string][]uint32{"main": {3, 1, 2}}
	result := DiffChanges(original, edited)
	if !result.Changed {
		t.Error("expected Changed=true for reorder")
	}
	if len(result.CloseWindows) != 0 {
		t.Errorf("expected no close windows, got %v", result.CloseWindows)
	}
}

func TestDiffChanges_Delete(t *testing.T) {
	original := map[string][]uint32{"main": {1, 2, 3}}
	edited := map[string][]uint32{"main": {1, 3}}
	result := DiffChanges(original, edited)
	if !result.Changed {
		t.Error("expected Changed=true for delete")
	}
	if len(result.CloseWindows) != 1 || result.CloseWindows[0] != 2 {
		t.Errorf("expected CloseWindows=[2], got %v", result.CloseWindows)
	}
}

func TestDiffChanges_CrossCellMove(t *testing.T) {
	original := map[string][]uint32{
		"main":    {1, 2},
		"sidebar": {3},
	}
	edited := map[string][]uint32{
		"main":    {1},
		"sidebar": {3, 2},
	}
	result := DiffChanges(original, edited)
	if !result.Changed {
		t.Error("expected Changed=true for cross-cell move")
	}
	if len(result.CloseWindows) != 0 {
		t.Errorf("expected no close windows, got %v", result.CloseWindows)
	}
}

func TestDiffChanges_NoChange(t *testing.T) {
	original := map[string][]uint32{"main": {1, 2, 3}}
	edited := map[string][]uint32{"main": {1, 2, 3}}
	result := DiffChanges(original, edited)
	if result.Changed {
		t.Error("expected Changed=false for no change")
	}
}

func TestParseBufferSingle_Deduplicate(t *testing.T) {
	buf := `67842  Firefox
67842  Firefox duplicate
12903  Alacritty
`
	result, err := ParseBufferSingle(buf, "main")
	if err != nil {
		t.Fatal(err)
	}
	if len(result["main"]) != 2 {
		t.Errorf("expected 2 windows after dedup, got %d", len(result["main"]))
	}
}
