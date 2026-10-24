.pragma library

// State shared by the widget copies (the shell runs one per monitor in the
// same engine; a .pragma library script is loaded once per engine).

// The copy whose panel is open, or null. Every copy hides its ticker while
// any panel is open, not just the one on the panel's monitor.
var openPanel = null

// Every live copy. IPC reaches only one of them (Quickshell ignores
// duplicate handlers for a target), so a poke from the herdr hook fans out
// from there.
var copies = []

function refreshAll() {
  for (var i = 0; i < copies.length; i++) copies[i].refresh()
}
