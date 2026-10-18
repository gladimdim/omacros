import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "Omacros.js" as Omacros

// Long-lived plugin service: owns the state file, syncs saved combos as
// runtime keybinds and types saved phrases on request. Firing happens over
// IPC — a Hyprland keybind runs
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
  readonly property string imagesDir: Omacros.imagesDir(home, stateHome)

  property string rawText: ""
  property bool ready: false
  property bool writing: false
  property var macros: []
  property bool pruned: false

  // Runtime bind state: what the service last successfully registered, so
  // syncs stay small, plus what it last warned about, so a stuck conflict
  // doesn't spam notifications.
  property var appliedBinds: []
  property string lastConflictNotice: ""

  function applyRaw(text) {
    rawText = String(text || "")
    var state = Omacros.parseState(rawText)
    macros = state.macros
    bindSync.restart()
    pruneImages()
  }

  // Once per shell start, after the state file parsed cleanly: drop stored
  // images no macro references any more.
  function pruneImages() {
    if (pruned || !Omacros.stateIsValid(rawText)) return
    pruned = true
    pruneProc.command = Omacros.pruneCommand(imagesDir, macros)
    pruneProc.running = true
  }

  function persist(state) {
    writing = true
    rawText = Omacros.encode(state)
    store.setText(rawText)
    writing = false
  }

  // Fire: set the clipboard from the saved phrase (Omarchy's own helper,
  // so the phrase also lands in the clipboard manager history) or the
  // stored image (wl-copy with its mime type), then ask
  // the running Hyprland to press the paste chord its own SUPER+V
  // "Universal paste" binding uses. wtype typing was dropped: a typed
  // phrase can be executed by a shell prompt and is slow for long texts.
  function fire(id) {
    var macro = Omacros.findMacro(macros, id)
    if (!macro) return
    if (copyProc.running) { copyProc.running = false }
    pasteEval.running = false
    var command = Omacros.pasteCopyCommand(macro, imagesDir)
    if (!command) return
    copyProc.command = command
    copyProc.running = true
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

  Component.onCompleted: {
    ensureDir.running = true
    syncBinds(true)
  }

  // ---- Runtime keybind sync ------------------------------------------------
  // The plugin registers each saved combo with the running Hyprland through
  // its Lua API (hl.bind / hl.unbind via hyprctl eval). Runtime binds live in
  // compositor state, not in any config file, so nothing in ~/.config/hypr is
  // read or written and nothing runs as root. Hyprland drops them on config
  // reload; the service re-applies on shell start, on every saved change and
  // whenever Hyprland reports a reload. Combos already bound to something
  // else are skipped and reported — another bind is never overridden.
  property var plannedChunk: ""

  function syncBinds(force) {
    if (!ready && !force) return
    if (bindQuery.running) { queuedSync.restart(); return }
    bindQuery.command = ["timeout", "5", "hyprctl", "binds", "-j"]
    bindQuery.running = true
  }

  function planBinds(raw) {
    var blocked = !ready
    var plan = Omacros.bindDiff(root.macros, Omacros.parseBinds(raw), root.appliedBinds)
    var notice = Omacros.takenNotice(plan.taken)
    if (notice !== "" && notice !== lastConflictNotice) {
      lastConflictNotice = notice
      notify("Omacros", notice)
    } else if (notice === "" && lastConflictNotice !== "") {
      lastConflictNotice = ""
    }
    if (blocked) return // still loading state; nothing to compare reliably yet

    var chunk = Omacros.evalLua(plan.bind, plan.unbind)
    if (chunk === "") {
      return
    }
    plannedChunk = chunk
    bindEval.command = ["timeout", "5", "hyprctl", "eval", chunk]
    bindEval.running = true
  }

  Process {
    id: ensureDir
    command: ["timeout", "5", "mkdir", "-p", root.dir]
    onExited: store.reload()
  }

  Process {
    id: bindQuery
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.planBinds(String(text || ""))
    }
  }

  Process {
    id: bindEval
    onExited: function(exitCode) {
      if (exitCode === 0) {
        // Cache as applied so the next sync is a no-op until something changes.
        root.appliedBinds = Omacros.appliedFor(root.macros)
      }
      // A failed eval is picked up again by the next state change or reload.
      plannedChunk = ""
    }
  }

  Timer {
    id: bindSync
    interval: 250
    onTriggered: root.syncBinds(false)
  }

  Timer {
    id: queuedSync
    interval: 400
    onTriggered: root.syncBinds(false)
  }

  // Hyprland forgets runtime binds whenever its config reloads; re-register.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (String(event && event.name ? event.name : "") === "configreloaded") {
        root.appliedBinds = []
        root.syncBinds(false)
      }
    }
  }

  Process {
    id: copyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") console.warn("omacros clipboard copy:", err)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.notify("Omacros", "Could not put the macro on the clipboard — edit it and save it again")
        return
      }
      pasteEval.command = ["timeout", "5", "hyprctl", "eval", Omacros.pasteEvalLua()]
      pasteEval.running = true
    }
  }

  Process {
    id: pasteEval
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) return
      // The phrase is on the clipboard regardless, so a failed paste
      // still leaves Ctrl+V working by hand.
      root.notify("Omacros", "Pasted nothing — the phrase is on your clipboard, press Ctrl+V")
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

    // The detached window lives in the same process, but asking Hyprland for
    // it floats/centers the window fresh each open in case a reload dropped
    // the rule since the shell started.
    function applyRules(): void {
      ruleProc.command = ["timeout", "5", "hyprctl", "eval",
        'hl.window_rule({ match = { title = "^Omacros$" }, float = true, center = true })']
      ruleProc.running = true
    }
  }

  Process {
    id: ruleProc
  }

  Process {
    id: pruneProc
  }
}
