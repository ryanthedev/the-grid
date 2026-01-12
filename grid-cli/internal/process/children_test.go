package process

import (
	"reflect"
	"testing"
)

func TestParsePIDs(t *testing.T) {
	tests := []struct {
		name   string
		output string
		want   []int
	}{
		{
			name:   "single pid",
			output: "12345\n",
			want:   []int{12345},
		},
		{
			name:   "multiple pids",
			output: "12345\n67890\n11111\n",
			want:   []int{12345, 67890, 11111},
		},
		{
			name:   "empty output",
			output: "",
			want:   []int{},
		},
		{
			name:   "whitespace only",
			output: "  \n  \n  ",
			want:   []int{},
		},
		{
			name:   "pids with extra whitespace",
			output: "  12345  \n  67890  \n",
			want:   []int{12345, 67890},
		},
		{
			name:   "mixed valid and invalid",
			output: "12345\nnotapid\n67890\n",
			want:   []int{12345, 67890},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parsePIDs(tt.output)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("parsePIDs() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetChildPIDs_NoChildren(t *testing.T) {
	// Test with PID 1 which won't have us as children
	// This primarily tests that empty results don't error
	pids, err := GetChildPIDs(999999999)
	if err != nil {
		t.Errorf("GetChildPIDs() unexpected error: %v", err)
	}
	if len(pids) != 0 {
		t.Errorf("GetChildPIDs(999999999) expected empty slice, got %v", pids)
	}
}

func TestGetDescendantPIDs_ZeroDepth(t *testing.T) {
	pids, err := GetDescendantPIDs(1, 0)
	if err != nil {
		t.Errorf("GetDescendantPIDs() unexpected error: %v", err)
	}
	if len(pids) != 0 {
		t.Errorf("GetDescendantPIDs with depth 0 should return empty slice, got %v", pids)
	}
}
