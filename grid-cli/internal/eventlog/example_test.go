package eventlog_test

import (
	"fmt"

	"github.com/yourusername/grid-cli/internal/eventlog"
)

func ExampleLog() {
	// Log a command start event
	eventlog.Log("cmd.start", map[string]any{
		"cmd":  "focus",
		"args": map[string]string{"dir": "east"},
		"rid":  "a1b2",
	})

	// Log a command end event
	eventlog.Log("cmd.end", map[string]any{
		"cmd":        "focus",
		"rid":        "a1b2",
		"status":     "ok",
		"duration_ms": 42,
	})

	// Example output format (compact JSON-lines):
	// {"t":1702840000,"ev":"cmd.start","cmd":"focus","args":{"dir":"east"},"rid":"a1b2"}
	// {"t":1702840001,"ev":"cmd.end","cmd":"focus","rid":"a1b2","status":"ok","duration_ms":42}

	fmt.Println("Events logged successfully")
	// Output: Events logged successfully
}
