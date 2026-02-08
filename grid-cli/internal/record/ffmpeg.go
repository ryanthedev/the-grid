package record

import "os/exec"

// FFmpegAvailable checks whether ffmpeg is on the PATH.
func FFmpegAvailable() bool {
	_, err := exec.LookPath("ffmpeg")
	return err == nil
}

// InstallHint returns human-readable install instructions.
func InstallHint() string {
	return "ffmpeg is required for GIF/MP4/WebM conversion.\nInstall with: brew install ffmpeg"
}
