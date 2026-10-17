import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Omacros.js" as Omacros

// Long-lived plugin service: owns the state file and types saved phrases
// on request. Firing happens over IPC — a Hyprland keybind runs
// `omarchy-shell gladimdim.omacros fire <id>`, which lands here — so the
// phrase types into whatever window has focus at that moment.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
  readonly property string dir: Omacros.stateDir(home, stateHome)
  readonly property string path: Omacros.statePath(home, stateHome)

  property string rawText: ""
  property bool ready: false
  property bool writing: false
  property var macros: []

  function applyRaw(text) {
    rawText = String(text || "")
    var state = Omacros.parseState(rawText)
    macros = state.macros
  }

  function persist(state) {
    writing = true
    rawText = Omacros.encode(state)
    store.setText(rawText)
    writing = false
  }

  // Type a saved phrase into the focused window. wtype runs under a timeout
  // so a hung Wayland connection can never leave a process behind.
  function fire(id) {
    var macro = Omacros.findMacro(macros, id)
    if (!macro) return
    if (typeProc.running) typeProc.running = false
    typeProc.command = ["timeout", "15", "wtype", macro.text]
    typeProc.running = true
  }

  function notify(title, body) {
    Util.execArgv([
      "omarchy-notification-send",
      "-g", "󰌌",
      "-u", "normal",
      "-t", "8000",
      Omacros.notifySafeText(title),
      Omacros.notifySafeText(body || "")
    ])
  }

  Component.onCompleted: ensureDir.running = true

  Process {
    id: ensureDir
    command: ["timeout", "5", "mkdir", "-p", root.dir]
    onExited: store.reload()
  }

  Process {
    id: typeProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") console.warn("omacros wtype:", err)
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 127)
        root.notify("Omacros", "wtype is not installed — install it to type phrases")
      else if (exitCode !== 0)
        console.warn("omacros wtype exited", exitCode)
    }
  }

  FileView {
    id: store
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root.writing) return
      root.ready = true
      root.applyRaw(text())
    }
    onLoadFailed: {
      root.ready = true
      root.applyRaw("")
    }
    onFileChanged: if (!root.writing) reload()
  }

  // Catch state edits that never fire watchChanges (some filesystems).
  Timer {
    interval: 10000
    running: root.ready
    repeat: true
    onTriggered: store.reload()
  }

  ShellIpc {
    target: Omacros.ipcTarget

    function fire(id: string): void {
      root.fire(id)
    }

    function reload(): void {
      store.reload()
    }

    function list(): string {
      return Omacros.listFor(root.macros)
    }
  }
}
