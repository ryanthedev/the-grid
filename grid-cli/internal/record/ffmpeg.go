package record

import "os/exec"

// ffmpegPaths lists common ffmpeg installation locations to check when ffmpeg
// is not in PATH (e.g., when launched from GUI app with minimal PATH)
var ffmpegPaths = []string{
	"ffmpeg",
	"/opt/homebrew/bin/ffmpeg",
	"/usr/local/bin/ffmpeg",
	"/usr/bin/ffmpeg",
}

// FindFfmpeg returns the path to ffmpeg binary, checking common locations
// if not found in PATH.
func FindFfmpeg() string {
	for _, p := range ffmpegPaths {
		if path, err := exec.LookPath(p); err == nil {
			return path
		}
	}
	return "ffmpeg"
}

// FFmpegAvailable checks whether ffmpeg can be found.
func FFmpegAvailable() bool {
	return FindFfmpeg() != "ffmpeg" || func() bool {
		_, err := exec.LookPath("ffmpeg")
		return err == nil
	}()
}

// InstallHint returns human-readable install instructions.
func InstallHint() string {
	return "ffmpeg is required for GIF/MP4/WebM conversion.\nInstall with: brew install ffmpeg"
}
