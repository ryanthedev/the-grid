package record

import (
	"fmt"
	"os/exec"
	"strconv"

	"github.com/ryanthedev/grid-cli/internal/types"
)

// QualityLevel controls encoding bitrate / CRF
type QualityLevel string

const (
	QualityLow    QualityLevel = "low"
	QualityMedium QualityLevel = "medium"
	QualityHigh   QualityLevel = "high"
)

// ParseQuality converts a string to a QualityLevel, defaulting to medium.
func ParseQuality(s string) QualityLevel {
	switch s {
	case "low":
		return QualityLow
	case "high":
		return QualityHigh
	default:
		return QualityMedium
	}
}

// Convert transcodes input to the desired output format using ffmpeg.
func Convert(input, output, format string, fps, width int, quality QualityLevel) error {
	switch format {
	case "gif":
		return convertGIF(input, output, fps, width, quality)
	case "mp4":
		return convertMP4(input, output, fps, width, quality)
	case "webm":
		return convertWebM(input, output, fps, width, quality)
	case "mov":
		// No conversion needed; screencapture outputs mov natively.
		return nil
	default:
		return fmt.Errorf("unsupported format: %s", format)
	}
}

// Stitch combines multiple video files into a single output, placing each
// capture at its real screen coordinates so the result matches the physical
// monitor arrangement. Uses a black canvas sized to the bounding box of all
// regions, with each input overlaid at its correct offset.
func Stitch(inputs []string, output string, regions []types.Rect) error {
	if len(inputs) == 1 {
		return exec.Command("mv", inputs[0], output).Run()
	}

	// Compute bounding box of all regions
	minX, minY := regions[0].X, regions[0].Y
	maxX := regions[0].X + regions[0].Width
	maxY := regions[0].Y + regions[0].Height
	for _, r := range regions[1:] {
		if r.X < minX {
			minX = r.X
		}
		if r.Y < minY {
			minY = r.Y
		}
		if rx := r.X + r.Width; rx > maxX {
			maxX = rx
		}
		if ry := r.Y + r.Height; ry > maxY {
			maxY = ry
		}
	}

	// Canvas size (ensure even dimensions for codec)
	canvasW := int(maxX-minX) &^ 1
	canvasH := int(maxY-minY) &^ 1

	n := len(inputs)
	args := []string{"-y",
		"-f", "lavfi", "-i", fmt.Sprintf("color=c=black:s=%dx%d:r=30", canvasW, canvasH),
	}
	for _, in := range inputs {
		args = append(args, "-i", in)
	}

	// Build overlay chain: base[canvas] -> overlay input 0 -> overlay input 1 -> ...
	// Input indices: 0=canvas, 1..n=captures
	filter := ""
	prev := "0:v"
	for i := 0; i < n; i++ {
		ox := int(regions[i].X - minX)
		oy := int(regions[i].Y - minY)
		outLabel := fmt.Sprintf("out%d", i)
		if i == n-1 {
			// Last overlay outputs directly (no label needed)
			filter += fmt.Sprintf("[%s][%d:v]overlay=%d:%d:shortest=1", prev, i+1, ox, oy)
		} else {
			filter += fmt.Sprintf("[%s][%d:v]overlay=%d:%d:shortest=1[%s];", prev, i+1, ox, oy, outLabel)
			prev = outLabel
		}
	}

	args = append(args, "-filter_complex", filter, "-an", output)

	cmd := exec.Command(FindFfmpeg(), args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ffmpeg stitch failed: %w\n%s", err, string(out))
	}
	return nil
}

func convertGIF(input, output string, fps, width int, quality QualityLevel) error {
	// GIF conversion uses palette generation for quality
	vf := fmt.Sprintf("fps=%d", fps)
	if width > 0 {
		vf += fmt.Sprintf(",scale=%d:-1:flags=lanczos", width)
	}

	// Palette generation
	paletteFile := output + ".palette.png"
	palArgs := []string{"-y", "-i", input, "-vf", vf + ",palettegen=stats_mode=diff", paletteFile}
	cmd := exec.Command(FindFfmpeg(), palArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("palette generation failed: %w\n%s", err, string(out))
	}

	// Dither settings by quality
	dither := "bayer:bayer_scale=5"
	switch quality {
	case QualityLow:
		dither = "none"
	case QualityHigh:
		dither = "sierra2_4a"
	}

	// Create GIF with palette
	filter := fmt.Sprintf("%s[x];[x][1:v]paletteuse=dither=%s", vf, dither)
	gifArgs := []string{"-y", "-i", input, "-i", paletteFile, "-filter_complex", filter, output}
	cmd = exec.Command(FindFfmpeg(), gifArgs...)
	out, err = cmd.CombinedOutput()

	// Clean up palette
	_ = exec.Command("rm", "-f", paletteFile).Run()

	if err != nil {
		return fmt.Errorf("GIF conversion failed: %w\n%s", err, string(out))
	}
	return nil
}

func convertMP4(input, output string, fps, width int, quality QualityLevel) error {
	crf := mp4CRF(quality)
	args := []string{"-y", "-i", input}

	vf := fmt.Sprintf("fps=%d", fps)
	if width > 0 {
		vf += fmt.Sprintf(",scale=%d:-2:flags=lanczos", width)
	}

	args = append(args, "-vf", vf,
		"-c:v", "libx264", "-preset", "medium",
		"-crf", strconv.Itoa(crf),
		"-pix_fmt", "yuv420p",
		"-an", output)

	cmd := exec.Command(FindFfmpeg(), args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("MP4 conversion failed: %w\n%s", err, string(out))
	}
	return nil
}

func convertWebM(input, output string, fps, width int, quality QualityLevel) error {
	crf := webmCRF(quality)
	args := []string{"-y", "-i", input}

	vf := fmt.Sprintf("fps=%d", fps)
	if width > 0 {
		vf += fmt.Sprintf(",scale=%d:-2:flags=lanczos", width)
	}

	args = append(args, "-vf", vf,
		"-c:v", "libvpx-vp9",
		"-crf", strconv.Itoa(crf), "-b:v", "0",
		"-an", output)

	cmd := exec.Command(FindFfmpeg(), args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("WebM conversion failed: %w\n%s", err, string(out))
	}
	return nil
}

func mp4CRF(q QualityLevel) int {
	switch q {
	case QualityLow:
		return 28
	case QualityHigh:
		return 18
	default:
		return 23
	}
}

func webmCRF(q QualityLevel) int {
	switch q {
	case QualityLow:
		return 40
	case QualityHigh:
		return 24
	default:
		return 31
	}
}
