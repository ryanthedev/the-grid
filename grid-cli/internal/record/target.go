package record

import (
	"fmt"
	"strconv"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/reconcile"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// TargetType identifies what to record
type TargetType string

const (
	TargetCell   TargetType = "cell"
	TargetWindow TargetType = "window"
	TargetScreen TargetType = "screen"
	TargetAll    TargetType = "all"
)

// Target is the parsed user intent before resolution
type Target struct {
	Type TargetType
	ID   string // optional: cell ID, window ID, or display number
}

// ResolvedTarget contains pixel bounds ready for capture
type ResolvedTarget struct {
	Label   string       // human-readable label for filename
	Regions []types.Rect // one region per capture (multiple for "all")
}

// ParseTarget parses positional args into a Target.
// Examples: [], ["cell"], ["cell", "A"], ["window", "123"], ["screen", "2"], ["all"]
func ParseTarget(args []string) (Target, error) {
	if len(args) == 0 {
		return Target{Type: TargetCell}, nil
	}

	switch args[0] {
	case "cell":
		t := Target{Type: TargetCell}
		if len(args) > 1 {
			t.ID = args[1]
		}
		return t, nil
	case "window":
		t := Target{Type: TargetWindow}
		if len(args) > 1 {
			t.ID = args[1]
		}
		return t, nil
	case "screen":
		t := Target{Type: TargetScreen}
		if len(args) > 1 {
			t.ID = args[1]
		}
		return t, nil
	case "all":
		return Target{Type: TargetAll}, nil
	default:
		return Target{}, fmt.Errorf("unknown target %q (expected cell, window, screen, or all)", args[0])
	}
}

// ResolveTarget converts a parsed target into pixel bounds using server state.
func ResolveTarget(target Target, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) (*ResolvedTarget, error) {
	switch target.Type {
	case TargetCell:
		return resolveCell(target, snap, rs, cfg)
	case TargetWindow:
		return resolveWindow(target, snap)
	case TargetScreen:
		return resolveScreen(target, snap)
	case TargetAll:
		return resolveAll(snap)
	default:
		return nil, fmt.Errorf("unknown target type: %s", target.Type)
	}
}

func resolveCell(target Target, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) (*ResolvedTarget, error) {
	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return nil, fmt.Errorf("no state for space %s", snap.SpaceID)
	}

	layoutID := spaceState.CurrentLayoutID
	if layoutID == "" {
		return nil, fmt.Errorf("no active layout")
	}

	layoutDef, err := cfg.GetLayout(layoutID)
	if err != nil {
		return nil, fmt.Errorf("layout %q not found: %w", layoutID, err)
	}

	cellBounds := reconcile.CalculateCellBounds(layoutDef, snap, spaceState)
	if cellBounds == nil {
		return nil, fmt.Errorf("could not calculate cell bounds")
	}

	cellID := target.ID
	if cellID == "" {
		// Use focused cell
		cellID = spaceState.FocusedCell
		if cellID == "" {
			return nil, fmt.Errorf("no focused cell")
		}
	}

	bounds, ok := cellBounds[cellID]
	if !ok {
		return nil, fmt.Errorf("cell %q not found in layout", cellID)
	}

	return &ResolvedTarget{
		Label:   fmt.Sprintf("cell-%s", cellID),
		Regions: []types.Rect{cellRectToRect(bounds)},
	}, nil
}

func resolveWindow(target Target, snap *server.Snapshot) (*ResolvedTarget, error) {
	var wid uint32
	if target.ID != "" {
		n, err := strconv.ParseUint(target.ID, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("invalid window ID %q: %w", target.ID, err)
		}
		wid = uint32(n)
	} else {
		wid = snap.FocusedWindowID
		if wid == 0 {
			return nil, fmt.Errorf("no focused window")
		}
	}

	win := snap.GetWindowByID(wid)
	if win == nil {
		return nil, fmt.Errorf("window %d not found", wid)
	}

	return &ResolvedTarget{
		Label:   fmt.Sprintf("window-%d", wid),
		Regions: []types.Rect{win.Frame},
	}, nil
}

func resolveScreen(target Target, snap *server.Snapshot) (*ResolvedTarget, error) {
	if len(snap.AllDisplays) == 0 {
		return nil, fmt.Errorf("no displays found")
	}

	if target.ID != "" {
		n, err := strconv.Atoi(target.ID)
		if err != nil {
			return nil, fmt.Errorf("invalid display number %q: %w", target.ID, err)
		}
		// 1-based indexing
		idx := n - 1
		if idx < 0 || idx >= len(snap.AllDisplays) {
			return nil, fmt.Errorf("display %d not found (have %d displays)", n, len(snap.AllDisplays))
		}
		d := snap.AllDisplays[idx]
		return &ResolvedTarget{
			Label:   fmt.Sprintf("screen-%d", n),
			Regions: []types.Rect{d.Frame},
		}, nil
	}

	// Current display
	uuid := snap.GetCurrentDisplayUUID()
	for _, d := range snap.AllDisplays {
		if d.UUID == uuid {
			return &ResolvedTarget{
				Label:   "screen",
				Regions: []types.Rect{d.Frame},
			}, nil
		}
	}

	// Fallback to first display
	d := snap.AllDisplays[0]
	return &ResolvedTarget{
		Label:   "screen",
		Regions: []types.Rect{d.Frame},
	}, nil
}

func resolveAll(snap *server.Snapshot) (*ResolvedTarget, error) {
	if len(snap.AllDisplays) == 0 {
		return nil, fmt.Errorf("no displays found")
	}

	var regions []types.Rect
	for _, d := range snap.AllDisplays {
		regions = append(regions, d.Frame)
	}

	// Sort by X position (left-to-right)
	sortRegionsByX(regions)

	return &ResolvedTarget{
		Label:   "all",
		Regions: regions,
	}, nil
}

func cellRectToRect(cr client.CellRect) types.Rect {
	return types.Rect{
		X:      cr.X,
		Y:      cr.Y,
		Width:  cr.Width,
		Height: cr.Height,
	}
}

func sortRegionsByX(regions []types.Rect) {
	for i := 1; i < len(regions); i++ {
		for j := i; j > 0 && regions[j].X < regions[j-1].X; j-- {
			regions[j], regions[j-1] = regions[j-1], regions[j]
		}
	}
}
