package logging

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

var logFile *os.File

// Init initializes the logging system
func Init() error {
	logDir := filepath.Join(os.Getenv("HOME"), ".local", "state", "thegrid")
	os.MkdirAll(logDir, 0755)

	logPath := filepath.Join(logDir, "grid-cli.log")
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	logFile = f
	return nil
}

// Log writes a formatted message to the log file
func Log(format string, args ...interface{}) {
	if logFile == nil {
		return
	}
	timestamp := time.Now().Format("2006-01-02 15:04:05.000")
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintf(logFile, "[%s] %s\n", timestamp, msg)
}

// Close closes the log file
func Close() {
	if logFile != nil {
		logFile.Close()
	}
}
