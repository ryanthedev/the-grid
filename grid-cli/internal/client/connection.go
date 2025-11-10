package client

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"time"

	"github.com/yourusername/grid-cli/internal/models"
)

// Connection manages the Unix domain socket connection to GridServer
type Connection struct {
	socketPath string
	conn       net.Conn
	reader     *bufio.Reader
	timeout    time.Duration
}

// NewConnection creates a new connection instance
func NewConnection(socketPath string, timeout time.Duration) *Connection {
	return &Connection{
		socketPath: socketPath,
		timeout:    timeout,
	}
}

// Connect establishes the Unix domain socket connection
func (c *Connection) Connect() error {
	var err error
	c.conn, err = net.Dial("unix", c.socketPath)
	if err != nil {
		return fmt.Errorf("failed to connect to socket %s: %w", c.socketPath, err)
	}
	c.reader = bufio.NewReader(c.conn)
	return nil
}

// Close closes the connection
func (c *Connection) Close() error {
	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

// SendRequest sends a request and waits for the response
func (c *Connection) SendRequest(ctx context.Context, req *models.MessageEnvelope) (*models.Response, error) {
	// Apply timeout if not already set
	if _, ok := ctx.Deadline(); !ok && c.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, c.timeout)
		defer cancel()
	}

	// Marshal and send request
	data, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	// Send with newline delimiter
	data = append(data, '\n')
	if err := c.conn.SetWriteDeadline(time.Now().Add(c.timeout)); err != nil {
		return nil, fmt.Errorf("failed to set write deadline: %w", err)
	}

	if _, err := c.conn.Write(data); err != nil {
		return nil, fmt.Errorf("failed to write request: %w", err)
	}

	// Read response with context cancellation support
	respChan := make(chan *models.Response, 1)
	errChan := make(chan error, 1)

	go func() {
		if err := c.conn.SetReadDeadline(time.Now().Add(c.timeout)); err != nil {
			errChan <- fmt.Errorf("failed to set read deadline: %w", err)
			return
		}

		line, err := c.reader.ReadBytes('\n')
		if err != nil {
			errChan <- fmt.Errorf("failed to read response: %w", err)
			return
		}

		var envelope models.MessageEnvelope
		if err := json.Unmarshal(line, &envelope); err != nil {
			errChan <- fmt.Errorf("failed to unmarshal response: %w", err)
			return
		}

		if envelope.Type != "response" {
			errChan <- fmt.Errorf("expected response, got %s", envelope.Type)
			return
		}

		if envelope.Response == nil {
			errChan <- fmt.Errorf("response envelope has nil response")
			return
		}

		respChan <- envelope.Response
	}()

	select {
	case <-ctx.Done():
		return nil, fmt.Errorf("request cancelled or timed out: %w", ctx.Err())
	case err := <-errChan:
		return nil, err
	case resp := <-respChan:
		return resp, nil
	}
}

// IsConnected returns true if the connection is established
func (c *Connection) IsConnected() bool {
	return c.conn != nil
}
