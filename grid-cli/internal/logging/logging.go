package logging

import (
	"os"
	"path/filepath"
	"time"

	"github.com/rs/zerolog"
)

var (
	Logger  zerolog.Logger
	logFile *os.File
)

// timestampHook adds timestamp at the end of each log event
type timestampHook struct{}

func (h timestampHook) Run(e *zerolog.Event, level zerolog.Level, msg string) {
	e.Time("ts", time.Now())
}

// Init initializes the logging system with zerolog
func Init() error {
	logDir := filepath.Join(os.Getenv("HOME"), ".local", "state", "thegrid")
	os.MkdirAll(logDir, 0755)

	logPath := filepath.Join(logDir, "grid-cli.log")
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	logFile = f

	// Set global level to Info
	zerolog.SetGlobalLevel(zerolog.InfoLevel)

	// Configure field names
	zerolog.MessageFieldName = "msg"

	// Create logger with hook that adds timestamp last
	Logger = zerolog.New(logFile).Hook(timestampHook{})

	return nil
}

// Close closes the log file
func Close() {
	if logFile != nil {
		logFile.Close()
	}
}

// Debug returns a debug level event
func Debug() *zerolog.Event {
	return Logger.Debug()
}

// Info returns an info level event
func Info() *zerolog.Event {
	return Logger.Info()
}

// Warn returns a warn level event
func Warn() *zerolog.Event {
	return Logger.Warn()
}

// Error returns an error level event
func Error() *zerolog.Event {
	return Logger.Error()
}
