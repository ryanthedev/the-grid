package record

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// Options holds all recording parameters.
type Options struct {
	Duration  int          // seconds to record
	Output    string       // output file path (empty = auto)
	OutputDir string       // default output directory (used when Output is empty)
	Format    string       // gif, mp4, webm, mov
	FPS       int          // 0 = auto (10 for gif, 30 for video)
	Width     int          // max output width (0 = no scaling)
	Quality   QualityLevel // low, medium, high
	Countdown int          // seconds before recording (0 = skip)
	Cursor    bool         // include cursor
	Open      bool         // open file after recording
	Follow    bool         // follow focused cell during recording
	FollowCtx *FollowContext // context for focus tracking (required when Follow=true)
}

// Result describes the output of a recording.
type Result struct {
	FilePath string `json:"filePath"`
	Format   string `json:"format"`
	Size     int64  `json:"size"`
	Duration int    `json:"duration"`
}

// DefaultOptions returns sensible defaults.
func DefaultOptions() Options {
	return Options{
		Duration:  5,
		Format:    "gif",
		FPS:       0,
		Quality:   QualityMedium,
		Countdown: 3,
	}
}

// EffectiveFPS returns the FPS to use, applying format-based defaults when FPS==0.
func (o *Options) EffectiveFPS() int {
	if o.FPS > 0 {
		return o.FPS
	}
	if o.Format == "gif" {
		return 10
	}
	return 30
}

// GenerateOutputPath creates an automatic output filename.
// If dir is non-empty, the file is placed in that directory.
func GenerateOutputPath(dir, label, format string) string {
	ts := time.Now().Format("20060102-150405")
	name := fmt.Sprintf("recording-%s-%s.%s", label, ts, format)
	if dir != "" {
		return filepath.Join(dir, name)
	}
	return name
}

// Record orchestrates the full capture pipeline.
func Record(ctx context.Context, resolved *ResolvedTarget, opts Options) (*Result, error) {
	span := jsonlog.StartSpan("record", jsonlog.WithData(map[string]any{
		"label":    resolved.Label,
		"format":   opts.Format,
		"duration": opts.Duration,
		"regions":  len(resolved.Regions),
	}))
	defer span.End()

	// Determine output path
	outPath := opts.Output
	if outPath == "" {
		outPath = GenerateOutputPath(opts.OutputDir, resolved.Label, opts.Format)
	}

	// Check ffmpeg requirement
	needsFFmpeg := opts.Format != "mov" || len(resolved.Regions) > 1
	if needsFFmpeg && !FFmpegAvailable() {
		fmt.Fprintf(os.Stderr, "Warning: %s\nFalling back to .mov format.\n", InstallHint())
		opts.Format = "mov"
		ext := filepath.Ext(outPath)
		if ext != "" && ext != ".mov" {
			outPath = outPath[:len(outPath)-len(ext)] + ".mov"
		}
	}

	fps := opts.EffectiveFPS()

	// Capture phase
	var capturedFile string
	if opts.Follow && opts.FollowCtx != nil {
		// Follow mode: capture full screen while tracking focus in parallel
		capturedFile = tempPath("recording", "mov")
		trackCtx, trackCancel := context.WithCancel(ctx)
		var focusEvents []FocusEvent
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			focusEvents = TrackFocus(trackCtx, *opts.FollowCtx, 100*time.Millisecond)
		}()

		if err := Capture(ctx, resolved.Regions[0], opts.Duration, opts.Cursor, capturedFile); err != nil {
			trackCancel()
			wg.Wait()
			return nil, err
		}
		trackCancel()
		wg.Wait()

		// Apply crop filter from focus events
		if len(focusEvents) > 0 {
			filter, outW, outH := BuildCropFilter(focusEvents, float64(opts.Duration))
			croppedFile := tempPath("cropped", "mov")
			if err := ApplyCropFilter(capturedFile, croppedFile, filter, outW, outH); err != nil {
				return nil, fmt.Errorf("follow crop failed: %w", err)
			}
			os.Remove(capturedFile)
			capturedFile = croppedFile
		}
	} else if len(resolved.Regions) == 1 {
		capturedFile = tempPath("recording", "mov")
		if err := Capture(ctx, resolved.Regions[0], opts.Duration, opts.Cursor, capturedFile); err != nil {
			return nil, err
		}
	} else {
		// Multi-region: capture in parallel, then stitch
		tmpFiles := make([]string, len(resolved.Regions))
		var wg sync.WaitGroup
		errs := make([]error, len(resolved.Regions))

		for i := range resolved.Regions {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				tmpFiles[idx] = tempPath(fmt.Sprintf("region-%d", idx), "mov")
				errs[idx] = Capture(ctx, resolved.Regions[idx], opts.Duration, opts.Cursor, tmpFiles[idx])
			}(i)
		}
		wg.Wait()

		for i, err := range errs {
			if err != nil {
				return nil, fmt.Errorf("capture region %d failed: %w", i, err)
			}
		}

		capturedFile = tempPath("stitched", "mov")
		if err := Stitch(tmpFiles, capturedFile, resolved.Regions); err != nil {
			return nil, fmt.Errorf("stitch failed: %w", err)
		}

		for _, f := range tmpFiles {
			os.Remove(f)
		}
	}
	defer os.Remove(capturedFile)

	// Convert phase
	if opts.Format == "mov" {
		if err := os.Rename(capturedFile, outPath); err != nil {
			return nil, fmt.Errorf("failed to move output: %w", err)
		}
	} else {
		if err := Convert(capturedFile, outPath, opts.Format, fps, opts.Width, opts.Quality); err != nil {
			return nil, err
		}
	}

	info, err := os.Stat(outPath)
	if err != nil {
		return nil, fmt.Errorf("output file missing: %w", err)
	}

	return &Result{
		FilePath: outPath,
		Format:   opts.Format,
		Size:     info.Size(),
		Duration: opts.Duration,
	}, nil
}

func tempPath(prefix, ext string) string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("thegrid-%s-%d.%s", prefix, time.Now().UnixNano(), ext))
}

