import AppKit

// Create and run NSApplication with our AppDelegate.
// NSApp.run() starts the event loop (required for keyboard/mouse events).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
