package tmux

// TerminalBundleIDs maps known terminal app bundle identifiers
var TerminalBundleIDs = map[string]bool{
	"com.mitchellh.ghostty":   true,
	"com.googlecode.iterm2":   true,
	"com.apple.Terminal":      true,
	"io.alacritty":            true,
	"net.kovidgoyal.kitty":    true,
	"com.github.wez.wezterm":  true,
}

// IsTerminalApp returns true if the bundle ID belongs to a known terminal
func IsTerminalApp(bundleID string) bool {
	return TerminalBundleIDs[bundleID]
}
