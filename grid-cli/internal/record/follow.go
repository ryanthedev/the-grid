package record

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/ryanthedev/grid-cli/internal/client"
	"github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
	"github.com/ryanthedev/grid-cli/internal/reconcile"
	"github.com/ryanthedev/grid-cli/internal/server"
	"github.com/ryanthedev/grid-cli/internal/state"
	"github.com/ryanthedev/grid-cli/internal/types"
)

// FocusEvent records a single focus change during recording.
type FocusEvent struct {
	Timestamp time.Duration
	CellID    string
	Bounds    types.Rect
}

// FollowContext bundles the dependencies TrackFocus needs to poll focus state.
type FollowContext struct {
	Client *client.Client
	Config *config.Config
}

// TrackFocus polls focus changes during recording and returns a deduplicated list.
func TrackFocus(ctx context.Context, fc FollowContext, interval time.Duration) []FocusEvent {
	events := []FocusEvent{}
	lastCellID := ""
	start := time.Now()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	event, err := pollOnce(fc, start)
	if err == nil {
		events = append(events, event)
		lastCellID = event.CellID
	}

	for {
		select {
		case <-ctx.Done():
			return events

		case <-ticker.C:
			event, err := pollOnce(fc, start)
			if err != nil {
				jsonlog.Log("follow.poll.err", jsonlog.WithMsg(err.Error()))
				continue
			}

			if event.CellID == lastCellID {
				continue
			}

			events = append(events, event)
			lastCellID = event.CellID
		}
	}
}

func pollOnce(fc FollowContext, start time.Time) (FocusEvent, error) {
	snap, err := server.Fetch(context.Background(), fc.Client)
	if err != nil {
		return FocusEvent{}, err
	}

	// Reload state from disk each poll — other commands (e.g. thegrid focus)
	// update FocusedCell on disk, so the in-memory copy from startup is stale.
	rs, err := state.LoadState()
	if err != nil {
		return FocusEvent{}, fmt.Errorf("failed to reload state: %w", err)
	}

	spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
	if spaceState == nil {
		return FocusEvent{}, fmt.Errorf("no state for space")
	}

	layoutID := spaceState.CurrentLayoutID
	if layoutID == "" {
		return FocusEvent{}, fmt.Errorf("no active layout")
	}

	layoutDef, err := fc.Config.GetLayout(layoutID)
	if err != nil {
		return FocusEvent{}, err
	}

	cellBounds := reconcile.CalculateCellBounds(layoutDef, snap, spaceState)
	if cellBounds == nil {
		return FocusEvent{}, fmt.Errorf("could not calculate cell bounds")
	}

	cellID := spaceState.FocusedCell
	if cellID == "" {
		return FocusEvent{}, fmt.Errorf("no focused cell")
	}

	bounds, ok := cellBounds[cellID]
	if !ok {
		return FocusEvent{}, fmt.Errorf("focused cell not in layout bounds")
	}

	return FocusEvent{
		Timestamp: time.Since(start),
		CellID:    cellID,
		Bounds:    cellRectToRect(bounds),
	}, nil
}

// BuildCropFilter constructs an ffmpeg filter_complex string for dynamic cell cropping.
func BuildCropFilter(events []FocusEvent, recordingDuration float64) (filter string, outW int, outH int) {
	maxW := 0.0
	maxH := 0.0
	for _, event := range events {
		if event.Bounds.Width > maxW {
			maxW = event.Bounds.Width
		}
		if event.Bounds.Height > maxH {
			maxH = event.Bounds.Height
		}
	}

	outW = int(maxW) &^ 1
	outH = int(maxH) &^ 1

	if outW < 2 {
		outW = 2
	}
	if outH < 2 {
		outH = 2
	}

	if len(events) == 1 {
		e := events[0]
		filter = fmt.Sprintf(
			"crop=%d:%d:%d:%d,scale=%d:%d",
			int(e.Bounds.Width), int(e.Bounds.Height),
			int(e.Bounds.X), int(e.Bounds.Y),
			outW, outH,
		)
		return filter, outW, outH
	}

	n := len(events)

	var parts []string

	splitLabels := ""
	for i := 0; i < n; i++ {
		splitLabels += fmt.Sprintf("[s%d]", i)
	}
	parts = append(parts, fmt.Sprintf("[0:v]split=%d%s", n, splitLabels))

	for i := 0; i < n; i++ {
		e := events[i]

		startTime := e.Timestamp.Seconds()

		var endTime float64
		if i < n-1 {
			endTime = events[i+1].Timestamp.Seconds()
		} else {
			endTime = recordingDuration
		}

		if endTime <= startTime {
			endTime = startTime + 0.001
		}

		cropW := int(e.Bounds.Width)
		cropH := int(e.Bounds.Height)
		cropX := int(e.Bounds.X)
		cropY := int(e.Bounds.Y)

		segment := fmt.Sprintf(
			"[s%d]crop=%d:%d:%d:%d,scale=%d:%d,trim=%.3f:%.3f,setpts=PTS-STARTPTS[c%d]",
			i, cropW, cropH, cropX, cropY,
			outW, outH,
			startTime, endTime,
			i,
		)
		parts = append(parts, segment)
	}

	concatInputs := ""
	for i := 0; i < n; i++ {
		concatInputs += fmt.Sprintf("[c%d]", i)
	}
	parts = append(parts, fmt.Sprintf("%sconcat=n=%d:v=1:a=0", concatInputs, n))

	filter = strings.Join(parts, ";")

	return filter, outW, outH
}

// ApplyCropFilter runs ffmpeg with the given filter to produce a cropped output.
func ApplyCropFilter(input, output, filter string, outW, outH int) error {
	args := []string{
		"-y",
		"-i", input,
		"-filter_complex", filter,
		"-an",
		output,
	}

	cmd := exec.Command("ffmpeg", args...)
	combinedOutput, err := cmd.CombinedOutput()

	if err != nil {
		return fmt.Errorf("ffmpeg crop failed: %w\n%s", err, string(combinedOutput))
	}

	return nil
}
