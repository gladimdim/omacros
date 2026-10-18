import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Omacros.js" as Omacros

BarWidget {
  id: root
  moduleName: "gladimdim.omacros"

  property var macros: []
  property bool countReady: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
  readonly property string path: Omacros.statePath(home, stateHome)
  readonly property bool opened: (listLoader.item && listLoader.item.opened === true)
  readonly property string statusTooltip: Omacros.tooltipFor(macros)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function injectList() {
    var target = listLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // summonBarWidget looks for open() on the live widget instance.
  function open() {
    Qt.callLater(root.openList)
  }

  function openList() {
    if (listLoader.item && listLoader.item.open) listLoader.item.open()
  }

  function closeList() {
    if (listLoader.item && listLoader.item.close) listLoader.item.close()
  }

  function close() {
    closeList()
  }

  function applyCount(text) {
    macros = Omacros.parseState(text).macros
    countReady = true
  }

  onBarChanged: injectList()
  onSettingsChanged: injectList()

  FileView {
    id: countStore
    path: root.path
    watchChanges: true
    printErrors: false
    onLoaded: root.applyCount(text())
    onLoadFailed: {
      root.applyCount("")
      // The service may still be creating the folder or migrating an older
      // state file into it; look again shortly.
      if (root.countRetries < 3) { root.countRetries++; countRetry.restart() }
    }
    onFileChanged: reload()
  }

  property int countRetries: 0

  Timer {
    id: countRetry
    interval: 2000
    onTriggered: countStore.reload()
  }

  // The window manages its own visibility (starts closed; open() shows it).
  // No visible:false wrapper here: it would cascade over a child Item
  // (QsWindow) and pin the window closed forever.
  Loader {
    id: listLoader
    active: true
    source: Qt.resolvedUrl("MacrosWindow.qml")
    onLoaded: {
      root.injectList()
      Qt.callLater(root.injectList)
    }
  }

  // A compositor close (SUPER+W, the window's X) tears down the backing
  // surface, and the window ignores visible = true after that, so the icon
  // would never open it again. Rebuild a fresh window instead.
  function rebuildList() {
    listLoader.active = false
    listLoader.active = true
  }

  Connections {
    target: listLoader.item
    function onClosed() {
      Qt.callLater(root.rebuildList)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    active: root.opened
    tooltipText: root.statusTooltip
    onPressed: function(mouse) {
      if (root.opened) root.closeList()
      else root.openList()
    }
  }

  // Runtime-bind notes for the window copy: the service wires saved combos
  // automatically, so the form points at behavior instead of a paste step.

  Rectangle {
    visible: root.countReady && root.macros.length > 0
    width: Math.max(10, badgeText.implicitWidth + 6)
    height: 12
    radius: 6
    color: Color.accent
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -3
    anchors.topMargin: 2

    Text {
      id: badgeText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.macros.length > 9 ? "9+" : String(root.macros.length)
      color: Color.background
      font.pixelSize: 8
      font.bold: true
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
    }
  }
}
