package client

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/ryanthedev/grid-cli/internal/models"
	"github.com/ryanthedev/grid-cli/internal/tracing"
)

const (
	DefaultSocketPath = "/tmp/grid-server.sock"
	DefaultTimeout    = 30 * time.Second
)

// Client is the main GridServer client
type Client struct {
	conn *Connection
}

// NewClient creates a new GridServer client
func NewClient(socketPath string, timeout time.Duration) *Client {
	if socketPath == "" {
		socketPath = DefaultSocketPath
	}
	if timeout == 0 {
		timeout = DefaultTimeout
	}

	return &Client{
		conn: NewConnection(socketPath, timeout),
	}
}

// Connect establishes connection to the server
func (c *Client) Connect() error {
	return c.conn.Connect()
}

// Close closes the connection
func (c *Client) Close() error {
	return c.conn.Close()
}

// Clone creates a new client with the same configuration but a fresh connection.
// Useful for parallel operations that need independent connections.
func (c *Client) Clone() *Client {
	return &Client{
		conn: NewConnection(c.conn.socketPath, c.conn.timeout),
	}
}

// request is a helper to send a request and get the response
func (c *Client) request(ctx context.Context, method string, params map[string]interface{}) (*models.Response, error) {
	if !c.conn.IsConnected() {
		if err := c.Connect(); err != nil {
			return nil, err
		}
	}

	// Initialize params if nil
	if params == nil {
		params = make(map[string]interface{})
	}

	// Extract trace info from context and inject into request
	tid, sid := tracing.GetTraceInfo(ctx)
	if tid != "" && sid != "" {
		params["_trace"] = map[string]string{
			"tid": tid,
			"sid": sid,
		}
	}

	req := models.NewRequest(uuid.New().String(), method, params)
	return c.conn.SendRequest(ctx, req)
}

// Ping sends a ping request to test connectivity
func (c *Client) Ping(ctx context.Context) (map[string]interface{}, error) {
	resp, err := c.request(ctx, "ping", nil)
	if err != nil {
		return nil, err
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	return resp.Result, nil
}

// GetServerInfo retrieves server information
func (c *Client) GetServerInfo(ctx context.Context) (map[string]interface{}, error) {
	resp, err := c.request(ctx, "getServerInfo", nil)
	if err != nil {
		return nil, err
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	return resp.Result, nil
}

// Dump retrieves the complete window manager state
func (c *Client) Dump(ctx context.Context) (map[string]interface{}, error) {
	resp, err := c.request(ctx, "dump", map[string]interface{}{})
	if err != nil {
		return nil, err
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	return resp.Result, nil
}

// UpdateWindow updates a window's properties
func (c *Client) UpdateWindow(ctx context.Context, windowID int, updates map[string]interface{}) (map[string]interface{}, error) {
	params := map[string]interface{}{
		"windowId": windowID,
	}

	// Merge updates into params
	for k, v := range updates {
		params[k] = v
	}

	resp, err := c.request(ctx, "updateWindow", params)
	if err != nil {
		return nil, err
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	return resp.Result, nil
}

// CloseWindow closes a window via the server's AX close button
func (c *Client) CloseWindow(ctx context.Context, windowID uint32) error {
	_, err := c.CallMethod(ctx, "window.close", map[string]interface{}{
		"windowId": fmt.Sprintf("%d", windowID),
	})
	return err
}

// CallMethod sends a generic RPC request with the given method and parameters
func (c *Client) CallMethod(ctx context.Context, method string, params map[string]interface{}) (map[string]interface{}, error) {
	resp, err := c.request(ctx, method, params)
	if err != nil {
		return nil, err
	}

	if resp.IsError() {
		return nil, fmt.Errorf("server error: %s", resp.GetError())
	}

	return resp.Result, nil
}
