package notify

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/yourusername/grid-cli/internal/models"
)

// Client wraps notification operations
type Client struct {
	conn NotifyConnection
}

// NotifyConnection is the interface for sending requests and waiting for events
type NotifyConnection interface {
	SendRequest(ctx context.Context, req *models.MessageEnvelope) (*models.Response, error)
	WaitForEvent(ctx context.Context, eventTypes ...string) (*models.Event, error)
}

// NewClient creates a new notification client
func NewClient(conn NotifyConnection) *Client {
	return &Client{conn: conn}
}

// Create sends a notification and waits for user response
// Returns the notification response (button click, text input, timeout, or cancel)
func (c *Client) Create(ctx context.Context, req *NotificationRequest) (*NotificationResponse, error) {
	// Build params
	params := map[string]interface{}{
		"notificationId": req.NotificationID,
		"title":          req.Title,
	}

	if req.Body != "" {
		params["body"] = req.Body
	}
	if len(req.Buttons) > 0 {
		params["buttons"] = req.Buttons
	}
	if req.TextInput {
		params["textInput"] = true
	}
	if req.TextMaxLength > 0 {
		params["textMaxLength"] = req.TextMaxLength
	}
	if req.Timeout > 0 {
		params["timeout"] = req.Timeout
	}
	if req.Position != nil {
		params["position"] = map[string]interface{}{
			"bounds": map[string]interface{}{
				"x":      req.Position.Bounds.X,
				"y":      req.Position.Bounds.Y,
				"width":  req.Position.Bounds.Width,
				"height": req.Position.Bounds.Height,
			},
			"anchor": req.Position.Anchor,
		}
	}

	// Send request
	envelope := models.NewRequest(uuid.New().String(), "notify.create", params)
	resp, err := c.conn.SendRequest(ctx, envelope)
	if err != nil {
		return nil, fmt.Errorf("failed to send notify.create: %w", err)
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	// Check if cached response
	status, _ := resp.Result["status"].(string)
	if status == "cached" {
		// Extract cached response
		if respData, ok := resp.Result["response"].(map[string]interface{}); ok {
			return ParseEventResponse(respData), nil
		}
		return nil, fmt.Errorf("cached response missing data")
	}

	// Status is "pending" - wait for event
	event, err := c.conn.WaitForEvent(ctx,
		EventTypeResponse,
		EventTypeTimeout,
		EventTypeCancelled,
		EventTypeError,
	)
	if err != nil {
		return nil, fmt.Errorf("failed waiting for notification event: %w", err)
	}

	// Parse event into response
	result := ParseEventResponse(event.Data)

	// Set flags based on event type
	switch event.EventType {
	case EventTypeTimeout:
		result.TimedOut = true
	case EventTypeCancelled:
		result.Cancelled = true
	case EventTypeError:
		if errMsg, ok := event.Data["error"].(string); ok {
			return nil, fmt.Errorf("notification error: %s", errMsg)
		}
		return nil, fmt.Errorf("notification error")
	}

	return result, nil
}

// Get retrieves a cached notification response
func (c *Client) Get(ctx context.Context, notificationID string) (*NotificationResponse, bool, error) {
	params := map[string]interface{}{
		"notificationId": notificationID,
	}

	envelope := models.NewRequest(uuid.New().String(), "notify.get", params)
	resp, err := c.conn.SendRequest(ctx, envelope)
	if err != nil {
		return nil, false, fmt.Errorf("failed to send notify.get: %w", err)
	}

	if resp.IsError() {
		return nil, false, fmt.Errorf("server error: %s", resp.GetError())
	}

	found, _ := resp.Result["found"].(bool)
	if !found {
		return nil, false, nil
	}

	if respData, ok := resp.Result["response"].(map[string]interface{}); ok {
		return ParseEventResponse(respData), true, nil
	}

	return nil, false, fmt.Errorf("response data missing")
}

// Cancel cancels a pending notification
func (c *Client) Cancel(ctx context.Context, notificationID string) (bool, error) {
	params := map[string]interface{}{
		"notificationId": notificationID,
	}

	envelope := models.NewRequest(uuid.New().String(), "notify.cancel", params)
	resp, err := c.conn.SendRequest(ctx, envelope)
	if err != nil {
		return false, fmt.Errorf("failed to send notify.cancel: %w", err)
	}

	if resp.IsError() {
		return false, fmt.Errorf("server error: %s", resp.GetError())
	}

	success, _ := resp.Result["success"].(bool)
	return success, nil
}

// List lists notifications
func (c *Client) List(ctx context.Context, filter string) ([]ListItem, error) {
	params := map[string]interface{}{}
	if filter != "" {
		params["status"] = filter
	}

	envelope := models.NewRequest(uuid.New().String(), "notify.list", params)
	resp, err := c.conn.SendRequest(ctx, envelope)
	if err != nil {
		return nil, fmt.Errorf("failed to send notify.list: %w", err)
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	var items []ListItem
	if notifications, ok := resp.Result["notifications"].([]interface{}); ok {
		for _, n := range notifications {
			if m, ok := n.(map[string]interface{}); ok {
				item := ListItem{}
				if v, ok := m["notificationId"].(string); ok {
					item.NotificationID = v
				}
				if v, ok := m["status"].(string); ok {
					item.Status = v
				}
				if v, ok := m["title"].(string); ok {
					item.Title = v
				}
				if v, ok := m["createdAt"].(string); ok {
					item.CreatedAt = v
				}
				if v, ok := m["button"].(string); ok {
					item.Button = &v
				}
				if v, ok := m["text"].(string); ok {
					item.Text = &v
				}
				if v, ok := m["cancelled"].(bool); ok {
					item.Cancelled = v
				}
				if v, ok := m["timedOut"].(bool); ok {
					item.TimedOut = v
				}
				if v, ok := m["timestamp"].(string); ok {
					item.Timestamp = v
				}
				items = append(items, item)
			}
		}
	}

	return items, nil
}

// Clear deletes a cached notification response
func (c *Client) Clear(ctx context.Context, notificationID string) (bool, error) {
	params := map[string]interface{}{
		"notificationId": notificationID,
	}

	envelope := models.NewRequest(uuid.New().String(), "notify.clear", params)
	resp, err := c.conn.SendRequest(ctx, envelope)
	if err != nil {
		return false, fmt.Errorf("failed to send notify.clear: %w", err)
	}

	if resp.IsError() {
		return false, fmt.Errorf("server error: %s", resp.GetError())
	}

	success, _ := resp.Result["success"].(bool)
	return success, nil
}

// CreateSimple is a convenience method for creating a simple button notification
func (c *Client) CreateSimple(ctx context.Context, id, title, body string, buttons []string, timeout time.Duration, position *NotificationPosition) (*NotificationResponse, error) {
	req := &NotificationRequest{
		NotificationID: id,
		Title:          title,
		Body:           body,
		Buttons:        buttons,
		Timeout:        int(timeout.Milliseconds()),
		Position:       position,
	}
	return c.Create(ctx, req)
}
