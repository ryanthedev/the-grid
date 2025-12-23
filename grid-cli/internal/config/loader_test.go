package config

import (
	"reflect"
	"testing"
)

func TestDeepMerge(t *testing.T) {
	tests := []struct {
		name     string
		base     map[string]any
		override map[string]any
		want     map[string]any
	}{
		{
			name: "nested object merge",
			base: map[string]any{
				"settings": map[string]any{
					"baseSpacing":      8,
					"animationDuration": 0.2,
				},
				"layouts": []any{
					map[string]any{"id": "base-layout"},
				},
			},
			override: map[string]any{
				"settings": map[string]any{
					"baseSpacing": 12,
				},
			},
			want: map[string]any{
				"settings": map[string]any{
					"baseSpacing":      12,
					"animationDuration": 0.2,
				},
				"layouts": []any{
					map[string]any{"id": "base-layout"},
				},
			},
		},
		{
			name: "null removes key",
			base: map[string]any{
				"settings": map[string]any{
					"baseSpacing":      8,
					"animationDuration": 0.2,
					"focusFollowsMouse": true,
				},
			},
			override: map[string]any{
				"settings": map[string]any{
					"animationDuration": nil,
				},
			},
			want: map[string]any{
				"settings": map[string]any{
					"baseSpacing":      8,
					"focusFollowsMouse": true,
				},
			},
		},
		{
			name: "array replacement",
			base: map[string]any{
				"layouts": []any{
					map[string]any{"id": "layout1"},
					map[string]any{"id": "layout2"},
				},
			},
			override: map[string]any{
				"layouts": []any{
					map[string]any{"id": "layout3"},
				},
			},
			want: map[string]any{
				"layouts": []any{
					map[string]any{"id": "layout3"},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := deepMerge(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("deepMerge() = %v, want %v", got, tt.want)
			}
		})
	}
}
