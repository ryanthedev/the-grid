// Package mutex provides a file-based mutex for CLI command serialization.
// This prevents race conditions when multiple CLI commands are triggered rapidly
// (e.g., via hotkeys) by ensuring only one command executes at a time.
package mutex

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

const (
	// LockFileName is the name of the lock file
	LockFileName = "cli.lock"

	// DefaultTimeout is how long to wait for the lock before giving up
	DefaultTimeout = 5 * time.Second

	// RetryInterval is how often to retry acquiring the lock
	RetryInterval = 10 * time.Millisecond
)

// CLIMutex represents a file-based mutex for CLI commands
type CLIMutex struct {
	lockPath string
	file     *os.File
	acquired bool
}

// New creates a new CLI mutex using a lock file in the state directory
func New(stateDir string) *CLIMutex {
	return &CLIMutex{
		lockPath: filepath.Join(stateDir, LockFileName),
	}
}

// Lock acquires the mutex with a timeout.
// Returns nil if the lock was acquired, or an error if it timed out.
func (m *CLIMutex) Lock(timeout time.Duration) error {
	if m.acquired {
		return nil // Already holding the lock
	}

	start := time.Now()
	deadline := start.Add(timeout)

	// Ensure the directory exists
	if err := os.MkdirAll(filepath.Dir(m.lockPath), 0755); err != nil {
		return fmt.Errorf("failed to create lock directory: %w", err)
	}

	// Open or create the lock file
	file, err := os.OpenFile(m.lockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return fmt.Errorf("failed to open lock file: %w", err)
	}

	// Try to acquire an exclusive lock with retries
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			// Lock acquired
			m.file = file
			m.acquired = true

			// Write our PID to the lock file for debugging
			file.Truncate(0)
			file.Seek(0, 0)
			fmt.Fprintf(file, "%d\n", os.Getpid())
			file.Sync()

			elapsed := time.Since(start)
			if elapsed > RetryInterval {
				// Only log if we had to wait
				jsonlog.Log("mutex.acquired", jsonlog.WithData(map[string]any{
					"waited_ms": elapsed.Milliseconds(),
				}))
			}
			return nil
		}

		// Check if we've exceeded the timeout
		if time.Now().After(deadline) {
			file.Close()
			jsonlog.Log("mutex.timeout", jsonlog.WithData(map[string]any{
				"timeout_ms": timeout.Milliseconds(),
			}))
			return fmt.Errorf("timeout waiting for CLI lock (another command may be running)")
		}

		// Wait and retry
		time.Sleep(RetryInterval)
	}
}

// Unlock releases the mutex
func (m *CLIMutex) Unlock() {
	if !m.acquired || m.file == nil {
		return
	}

	// Release the lock
	syscall.Flock(int(m.file.Fd()), syscall.LOCK_UN)
	m.file.Close()
	m.file = nil
	m.acquired = false
}

// TryLock attempts to acquire the lock without waiting.
// Returns true if the lock was acquired, false otherwise.
func (m *CLIMutex) TryLock() bool {
	if m.acquired {
		return true
	}

	// Ensure the directory exists
	if err := os.MkdirAll(filepath.Dir(m.lockPath), 0755); err != nil {
		return false
	}

	file, err := os.OpenFile(m.lockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return false
	}

	err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err != nil {
		file.Close()
		return false
	}

	m.file = file
	m.acquired = true

	// Write PID
	file.Truncate(0)
	file.Seek(0, 0)
	fmt.Fprintf(file, "%d\n", os.Getpid())
	file.Sync()

	return true
}
