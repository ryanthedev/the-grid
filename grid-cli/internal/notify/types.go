package notify

import "time"

// NotificationRequest is the request to create a notification
type NotificationRequest struct {
	NotificationID string              `json:"notificationId"`
	Title          string              `json:"title"`
	Body           string              `json:"body,omitempty"`
	Buttons        []string            `json:"buttons,omitempty"`
	TextInput      bool                `json:"textInput,omitempty"`
	TextMaxLength  int                 `json:"textMaxLength,omitempty"`
	Timeout        int                 `json:"timeout,omitempty"` // milliseconds
	Position       *NotificationPosition `json:"position"`
}

// NotificationPosition specifies where to display the notification
type NotificationPosition struct {
	Bounds NotificationBounds `json:"bounds"`
	Anchor string             `json:"anchor"` // top-right, top-left, bottom-right, bottom-left, center
}

// NotificationBounds is the cell bounds for positioning
type NotificationBounds struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// NotificationResponse is the response from a notification
type NotificationResponse struct {
	NotificationID string     `json:"notificationId"`
	Button         *string    `json:"button,omitempty"`
	Text           *string    `json:"text,omitempty"`
	Cancelled      bool       `json:"cancelled,omitempty"`
	TimedOut       bool       `json:"timedOut,omitempty"`
	Timestamp      time.Time  `json:"timestamp"`
}

// CreateResult is the immediate response from notify.create
type CreateResult struct {
	Status         string                `json:"status"` // "pending" or "cached"
	NotificationID string                `json:"notificationId,omitempty"`
	Response       *NotificationResponse `json:"response,omitempty"` // if cached
}

// GetResult is the response from notify.get
type GetResult struct {
	Found    bool                  `json:"found"`
	Response *NotificationResponse `json:"response,omitempty"`
}

// ListItem is a notification in the list
type ListItem struct {
	NotificationID string  `json:"notificationId"`
	Status         string  `json:"status"` // "active" or "cached"
	Title          string  `json:"title,omitempty"`
	CreatedAt      string  `json:"createdAt,omitempty"`
	Button         *string `json:"button,omitempty"`
	Text           *string `json:"text,omitempty"`
	Cancelled      bool    `json:"cancelled,omitempty"`
	TimedOut       bool    `json:"timedOut,omitempty"`
	Timestamp      string  `json:"timestamp,omitempty"`
}

// ListResult is the response from notify.list
type ListResult struct {
	Notifications []ListItem `json:"notifications"`
}

// Event types for notification events
const (
	EventTypeResponse  = "notify.response"
	EventTypeTimeout   = "notify.timeout"
	EventTypeCancelled = "notify.cancelled"
	EventTypeError     = "notify.error"
)

// NotificationEvent is an event received from the server
type NotificationEvent struct {
	EventType string                 `json:"eventType"`
	Data      map[string]interface{} `json:"data"`
}

// ParseEventResponse extracts a NotificationResponse from event data
func ParseEventResponse(data map[string]interface{}) *NotificationResponse {
	resp := &NotificationResponse{}

	if id, ok := data["notificationId"].(string); ok {
		resp.NotificationID = id
	}

	if btn, ok := data["button"].(string); ok {
		resp.Button = &btn
	}

	if txt, ok := data["text"].(string); ok {
		resp.Text = &txt
	}

	if ts, ok := data["timestamp"].(string); ok {
		if t, err := time.Parse(time.RFC3339, ts); err == nil {
			resp.Timestamp = t
		}
	}

	return resp
}
