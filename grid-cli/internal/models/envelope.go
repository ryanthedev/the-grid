package models

import (
	"encoding/json"
	"time"
)

// MessageEnvelope is the top-level message structure for all communications
type MessageEnvelope struct {
	Type     string         `json:"type"` // "request", "response", or "event"
	Request  *Request       `json:"request"`
	Response *Response      `json:"response"`
	Event    *Event         `json:"event"`
}

// Request represents an RPC request
type Request struct {
	ID     string                 `json:"id"`
	Method string                 `json:"method"`
	Params map[string]interface{} `json:"params"`
}

// Response represents an RPC response
type Response struct {
	ID     string                 `json:"id"`
	Result map[string]interface{} `json:"result,omitempty"`
	Error  *ErrorInfo             `json:"error,omitempty"`
}

// ErrorInfo represents an error in a response
type ErrorInfo struct {
	Code    int                    `json:"code"`
	Message string                 `json:"message"`
	Data    map[string]interface{} `json:"data,omitempty"`
}

// Event represents an asynchronous event from the server
type Event struct {
	EventType string                 `json:"eventType"`
	Data      map[string]interface{} `json:"data"`
	Timestamp time.Time              `json:"timestamp"`
}

// NewRequest creates a new request envelope
func NewRequest(id, method string, params map[string]interface{}) *MessageEnvelope {
	return &MessageEnvelope{
		Type: "request",
		Request: &Request{
			ID:     id,
			Method: method,
			Params: params,
		},
	}
}

// IsError returns true if the response contains an error
func (r *Response) IsError() bool {
	return r.Error != nil
}

// GetError returns the error message if present
func (r *Response) GetError() string {
	if r.Error != nil {
		return r.Error.Message
	}
	return ""
}

// MarshalJSON implements custom JSON marshaling for MessageEnvelope
func (m *MessageEnvelope) MarshalJSON() ([]byte, error) {
	type Alias MessageEnvelope
	return json.Marshal(&struct {
		*Alias
	}{
		Alias: (*Alias)(m),
	})
}
