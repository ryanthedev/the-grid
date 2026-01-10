package client

import (
	"context"
	"fmt"
)

// PickerItem represents an item in the picker
type PickerItem struct {
	ID         string            `json:"id"`
	Display    string            `json:"display"`
	Searchable []string          `json:"searchable,omitempty"`
	Metadata   map[string]string `json:"metadata,omitempty"`
}

// PickerStyle contains optional style overrides
type PickerStyle struct {
	Width                   *float64 `json:"width,omitempty"`
	MaxVisibleItems         *int     `json:"maxVisibleItems,omitempty"`
	ItemHeight              *float64 `json:"itemHeight,omitempty"`
	FontSize                *float64 `json:"fontSize,omitempty"`
	BackgroundColor         *string  `json:"backgroundColor,omitempty"`
	TextColor               *string  `json:"textColor,omitempty"`
	SelectedBackgroundColor *string  `json:"selectedBackgroundColor,omitempty"`
	MatchHighlightColor     *string  `json:"matchHighlightColor,omitempty"`
}

// PickerResult represents the result of showing the picker
type PickerResult struct {
	Cancelled bool                   `json:"cancelled"`
	Selected  map[string]interface{} `json:"selected"`
}

// SelectedItem returns the selected PickerItem, or nil if cancelled
func (r *PickerResult) SelectedItem() *PickerItem {
	if r.Cancelled || r.Selected == nil {
		return nil
	}

	item := &PickerItem{}
	if id, ok := r.Selected["id"].(string); ok {
		item.ID = id
	}
	if display, ok := r.Selected["display"].(string); ok {
		item.Display = display
	}
	if searchable, ok := r.Selected["searchable"].([]interface{}); ok {
		for _, s := range searchable {
			if str, ok := s.(string); ok {
				item.Searchable = append(item.Searchable, str)
			}
		}
	}
	if metadata, ok := r.Selected["metadata"].(map[string]interface{}); ok {
		item.Metadata = make(map[string]string)
		for k, v := range metadata {
			if str, ok := v.(string); ok {
				item.Metadata[k] = str
			}
		}
	}

	return item
}

// ShowPicker displays a picker with the given items and returns the selection
func (c *Client) ShowPicker(ctx context.Context, items []PickerItem, style *PickerStyle) (*PickerResult, error) {
	// Build items array for request
	itemsArray := make([]map[string]interface{}, len(items))
	for i, item := range items {
		itemMap := map[string]interface{}{
			"id":      item.ID,
			"display": item.Display,
		}
		if len(item.Searchable) > 0 {
			itemMap["searchable"] = item.Searchable
		}
		if len(item.Metadata) > 0 {
			itemMap["metadata"] = item.Metadata
		}
		itemsArray[i] = itemMap
	}

	params := map[string]interface{}{
		"items": itemsArray,
	}

	// Add style if provided
	if style != nil {
		styleMap := make(map[string]interface{})
		if style.Width != nil {
			styleMap["width"] = *style.Width
		}
		if style.MaxVisibleItems != nil {
			styleMap["maxVisibleItems"] = *style.MaxVisibleItems
		}
		if style.ItemHeight != nil {
			styleMap["itemHeight"] = *style.ItemHeight
		}
		if style.FontSize != nil {
			styleMap["fontSize"] = *style.FontSize
		}
		if style.BackgroundColor != nil {
			styleMap["backgroundColor"] = *style.BackgroundColor
		}
		if style.TextColor != nil {
			styleMap["textColor"] = *style.TextColor
		}
		if style.SelectedBackgroundColor != nil {
			styleMap["selectedBackgroundColor"] = *style.SelectedBackgroundColor
		}
		if style.MatchHighlightColor != nil {
			styleMap["matchHighlightColor"] = *style.MatchHighlightColor
		}
		if len(styleMap) > 0 {
			params["style"] = styleMap
		}
	}

	resp, err := c.request(ctx, "picker.show", params)
	if err != nil {
		return nil, err
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	result := &PickerResult{}
	if cancelled, ok := resp.Result["cancelled"].(bool); ok {
		result.Cancelled = cancelled
	}
	if selected, ok := resp.Result["selected"].(map[string]interface{}); ok {
		result.Selected = selected
	}

	return result, nil
}
