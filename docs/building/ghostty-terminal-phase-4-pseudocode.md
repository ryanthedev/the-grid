# Phase 4 Pseudocode: CLI Terminal Command

## Logic Flow
```
terminalCmd.RunE:
    connect to grid-server
    snap = Fetch(ctx, c)

    // Search snapshot for existing Ghostty terminal window
    termWin = find window where Title=="grid-terminal" AND BundleID=="com.mitchellh.ghostty"

    widFile = ~/.local/state/thegrid/terminal-wid

    IF termWin found:
        // Window is visible -> hide it
        save termWin.ID to widFile
        call "window.hide" RPC
        return

    IF saved WID exists in widFile:
        // Check if window is ordered out (hidden but alive)
        result = call "window.isOrderedIn" RPC
        IF result.isOrderedIn == false:
            // Hidden window -> show it
            call "window.show" RPC
            return
        // If isOrderedIn is true or RPC failed, window may be gone

    // No existing window -> launch new Ghostty
    exec: open -na Ghostty.app --args
        --title=grid-terminal
        --window-decoration=none
        --quit-after-last-window-closed=true
        -e tmux new-session -A -s grid-scratch

    // Poll for new window (up to 5s)
    FOR 50 iterations, 100ms sleep:
        snap = Fetch(ctx, c)
        termWin = find ghostty window in snap
        IF found: break

    IF not found: return timeout error

    // Configure new window: float above + sticky
    save newWin.ID to widFile
    call "window.setLayer" with layer="above"
    call "window.setSticky" with sticky=true
    return
```

## Helper Functions
```
saveTerminalWID(path, wid uint32):
    write wid as string to file

loadTerminalWID(path) -> (uint32, error):
    read file, parse uint32
```
