package config

import "github.com/yourusername/grid-cli/internal/types"

var builtinLayouts = map[string]LayoutConfig{
	"two-column-tabs": {
		ID:   "two-column-tabs",
		Name: "Two Column Tabs",
		Grid: GridConfig{
			Columns: []string{"1fr", "1fr"},
			Rows:    []string{"1fr"},
		},
		Cells: []CellConfig{
			{ID: "left", Column: "1/2", Row: "1/2"},
			{ID: "right", Column: "2/3", Row: "1/2"},
		},
		CellModes: map[string]types.StackMode{
			"left":  types.StackTabs,
			"right": types.StackTabs,
		},
	},
}

func GetBuiltinLayout(id string) *LayoutConfig {
	if layout, ok := builtinLayouts[id]; ok {
		return &layout
	}
	return nil
}
