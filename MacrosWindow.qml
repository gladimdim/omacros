import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Omacros.js" as Omacros

// Macro manager in a detached, resizable window: a real toplevel, not a bar
// popup, so it keeps its size (default 60% of screen) however its content
// changes and can be moved and resized like any window. Service.qml asks
// Hyprland to float, center and pin it via a runtime window rule.
Window {
  id: root
  moduleName: "gladimdim.omacros"

  property var bar: null
  property var settings: null
  property var hostWidget: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
  readonly property string path: Omacros.statePath(home, stateHome)
  readonly property color contentForeground: bar ? bar.foreground : Color.popups.text
  readonly property color contentMuted: Qt.darker(contentForeground, 1.4)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Color.popups.background
  readonly property color separator: Util.alpha(contentForeground, 0.14)

  readonly property bool opened: root.visible
  readonly property int defaultWidth: Math.round(root.defaultScreenW * 0.6)
  readonly property int defaultHeight: Math.round(root.defaultScreenH * 0.6)
  property int defaultScreenW: 1920
  property int defaultScreenH: 1080
  property bool sizedOnce: false

  property var macros: []
  property string rawText: ""
  property bool writing: false
  property bool recording: false
  property string heldMods: ""
  property var comboTokens: []
  property string comboKeys: ""
  property string statusText: ""
  property bool statusIsError: false
  property string pendingFireId: ""

  minimumWidth: 640
  minimumHeight: 420
  title: "Omacros"
  color: root.surface
  visible: false

  onVisibleChanged: if (root.visible) root.welcomed()

  function open() {
    applyRules()
    showDelay.restart()
  }

  function close() {
    root.visible = false
  }

  // The rule lives in Hyprland's runtime state, so re-ask before opening in
  // case a hyprland reload dropped it since the shell started.
  function applyRules() {
    IpcRegistry.call(Omacros.ipcTarget, Omacros.applyRulesMethod, [])
  }

  // Size comes from the screen on first open only; after that the user's
  // own resize wins for the rest of the session.
  function rememberScreen() {
    defaultScreenW = root.screen ? root.screen.width : 1920
    defaultScreenH = root.screen ? root.screen.height : 1080
  }

  function welcomed() {
    if (!root.sizedOnce) {
      root.width = root.defaultWidth
      root.height = root.defaultHeight
      root.sizedOnce = true
    }
    root.requestActivate()
    list.forceActiveFocus()
    reload()
  }

  Timer {
    id: showDelay
    interval: 150
    onTriggered: {
      root.rememberScreen()
      root.visible = true
    }
  }

  function reload() {
    store.reload()
  }

  function apply(text) {
    rawText = String(text || "")
    macros = Omacros.parseState(rawText).macros
    if (list.currentIndex >= macros.length) list.currentIndex = Math.max(0, macros.length - 1)
  }

  function persist(state) {
    writing = true
    rawText = Omacros.encode(state)
    store.setText(rawText)
    macros = state.macros
    writing = false
  }

  function setStatus(text, isError) {
    statusText = String(text || "")
    statusIsError = isError === true
  }

  function clearForm() {
    comboTokens = []
    comboKeys = ""
    heldMods = ""
    labelField.text = ""
    phraseField.text = ""
  }

  function startRecording() {
    recording = true
    heldMods = ""
    setStatus("Press the key combo now — hold modifiers first. Esc cancels.", false)
    recordTimer.restart()
    recordChip.forceActiveFocus()
  }

  function cancelRecording() {
    finishRecording(false, null)
    setStatus("", false)
  }

  function finishRecording(committed, tokens) {
    recording = false
    heldMods = ""
    recordTimer.stop()
    list.forceActiveFocus()
    if (!committed) return
    comboTokens = tokens
    comboKeys = Omacros.displayKeys(tokens)
  }

  function save() {
    if (recording) cancelRecording()
    var result = Omacros.addMacro(rawText, {
      label: labelField.text,
      tokens: comboTokens,
      text: phraseField.text
    })
    if (!result.ok) { setStatus(result.error, true); return }
    persist(result.state)
    clearForm()
    selectMacro(result.macro.id)
    setStatus("Saved. The combo is wired up automatically — press " + result.macro.keys + " in any window. Omacros notifies you if that combo is already taken.", false)
  }

  function deleteMacro(id) {
    var result = Omacros.removeMacro(rawText, id)
    if (!result.ok) return
    persist(result.state)
    setStatus("Deleted", false)
  }

  function selectedMacro() {
    if (list.currentIndex < 0 || list.currentIndex >= root.macros.length) return null
    return root.macros[list.currentIndex]
  }

  function selectMacro(id) {
    for (var i = 0; i < root.macros.length; i++) {
      if (root.macros[i].id === id) { list.currentIndex = i; return }
    }
  }

  function deleteSelected() {
    var macro = root.selectedMacro()
    if (!macro) return
    root.deleteMacro(macro.id)
  }

  // Insert the selected phrase into whatever had focus before this window
  // took it: it closes first so wtype lands there, not in the form.
  function runSelected() {
    var macro = root.selectedMacro()
    if (!macro) return
    pendingFireId = macro.id
    close()
    fireDelay.restart()
  }

  function doFire() {
    var id = pendingFireId
    pendingFireId = ""
    if (!id) return
    IpcRegistry.call(Omacros.ipcTarget, Omacros.fireMethod, [id])
  }

  function modsFromMask(mask) {
    var mods = []
    var map = {}
    map[Qt.MetaModifier] = "SUPER"
    map[Qt.ControlModifier] = "CTRL"
    map[Qt.AltModifier] = "ALT"
    map[Qt.ShiftModifier] = "SHIFT"
    var order = Omacros.modifierTokens
    for (var i = 0; i < order.length; i++) {
      for (var bit in map) {
        if (map[bit] === order[i] && (mask & Number(bit))) { mods.push(order[i]); break }
      }
    }
    return mods
  }

  function isModifierKey(key) {
    return key === Qt.Key_Meta || key === Qt.Key_Control || key === Qt.Key_Shift
        || key === Qt.Key_Alt || key === Qt.Key_AltGr || key === Qt.Key_NumLock
        || key === Qt.Key_Super_L || key === Qt.Key_Super_R
  }

  property var specialKeys: ({})
  Component.onCompleted: initSpecialKeys()

  function initSpecialKeys() {
    var map = specialKeys
    map[Qt.Key_Space] = "space"
    map[Qt.Key_Return] = "return"
    map[Qt.Key_Enter] = "return"
    map[Qt.Key_Tab] = "tab"
    map[Qt.Key_Backtab] = "tab"
    map[Qt.Key_Escape] = "escape"
    map[Qt.Key_Backspace] = "backspace"
    map[Qt.Key_Delete] = "delete"
    map[Qt.Key_Insert] = "insert"
    map[Qt.Key_Home] = "home"
    map[Qt.Key_End] = "end"
    map[Qt.Key_PageUp] = "prior"
    map[Qt.Key_PageDown] = "next"
    map[Qt.Key_Left] = "left"
    map[Qt.Key_Right] = "right"
    map[Qt.Key_Up] = "up"
    map[Qt.Key_Down] = "down"
    map[Qt.Key_Minus] = "minus"
    map[Qt.Key_Equal] = "equal"
    map[Qt.Key_Comma] = "comma"
    map[Qt.Key_Period] = "period"
    map[Qt.Key_Slash] = "slash"
    map[Qt.Key_Backslash] = "backslash"
    map[Qt.Key_Semicolon] = "semicolon"
    map[Qt.Key_Apostrophe] = "apostrophe"
    map[Qt.Key_BracketLeft] = "bracketleft"
    map[Qt.Key_BracketRight] = "bracketright"
    map[Qt.Key_QuoteLeft] = "grave"
    map[Qt.Key_Less] = "less"
    map[Qt.Key_Greater] = "greater"
    map[Qt.Key_Question] = "question"
    map[Qt.Key_Exclam] = "exclam"
    map[Qt.Key_QuoteDbl] = "quotedbl"
    map[Qt.Key_Colon] = "colon"
    map[Qt.Key_Ampersand] = "ampersand"
    map[Qt.Key_Asterisk] = "asterisk"
    map[Qt.Key_ParenLeft] = "parenleft"
    map[Qt.Key_ParenRight] = "parenright"
    map[Qt.Key_Underscore] = "underscore"
    map[Qt.Key_Plus] = "plus"
    map[Qt.Key_BraceLeft] = "braceleft"
    map[Qt.Key_BraceRight] = "braceright"
    map[Qt.Key_AsciiCircum] = "asciicircum"
    map[Qt.Key_AsciiTilde] = "asciitilde"
    map[Qt.Key_Bar] = "bar"
    map[Qt.Key_At] = "at"
    map[Qt.Key_Dollar] = "dollar"
    map[Qt.Key_Percent] = "percent"
    map[Qt.Key_NumberSign] = "numbersign"
    map[Qt.Key_Print] = "print"
    map[Qt.Key_Menu] = "menu"
    map[Qt.Key_CapsLock] = "caps_lock"
    map[Qt.Key_F1] = "F1"
    map[Qt.Key_F2] = "F2"
    map[Qt.Key_F3] = "F3"
    map[Qt.Key_F4] = "F4"
    map[Qt.Key_F5] = "F5"
    map[Qt.Key_F6] = "F6"
    map[Qt.Key_F7] = "F7"
    map[Qt.Key_F8] = "F8"
    map[Qt.Key_F9] = "F9"
    map[Qt.Key_F10] = "F10"
    map[Qt.Key_F11] = "F11"
    map[Qt.Key_F12] = "F12"
  }

  // Qt keyrise to one of the whitelisted keyNames: specialKeys covers
  // everything above letter/digit, the produced character covers the rest.
  function keysymName(key, text) {
    var special = specialKeys[key]
    if (special) return special
    if (text && text.length === 1) {
      var ch = text.toLowerCase()
      if ((ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")) return ch
    }
    return ""
  }

  function recordPressed(event) {
    if (event.key === Qt.Key_Escape) { cancelRecording(); event.accepted = true; return }
    if (isModifierKey(event.key)) {
      heldMods = modsFromMask(event.modifiers).join(" + ")
      event.accepted = true
      return
    }
    var keyName = keysymName(event.key, event.text)
    if (!keyName) {
      finishRecording(false, null)
      setStatus("That key isn't supported yet — letters, digits, F1-F12 and punctuation are", true)
      return
    }
    var tokens = modsFromMask(event.modifiers)
    tokens.push(keyName)
    finishRecording(true, tokens)
    event.accepted = true
  }

  // Esc inside the form blurs back to the list, it doesn't close the window.
  function fieldEscape(event) {
    if (event.key !== Qt.Key_Escape) return
    if (root.recording) root.cancelRecording()
    list.forceActiveFocus()
    event.accepted = true
  }

  Item {
    id: content
    anchors.fill: parent
    anchors.margins: Style.space(16)

    // Esc here closes the window; anything that wants it (fields, recorder)
    // accepts the event first.
    Keys.onPressed: function(event) {
      if (event.key !== Qt.Key_Escape) return
      if (root.recording) { root.cancelRecording(); return }
      root.close()
      event.accepted = true
    }

    Column {
      id: topColumn
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: "Omacros"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          verticalAlignment: Text.AlignVCenter
        }

        Text {
          textFormat: Text.PlainText
          text: root.macros.length + (root.macros.length === 1 ? " macro" : " macros")
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }

        Item { width: 1; height: 1 }

        Rectangle {
          width: Style.space(28)
          height: Style.space(28)
          radius: Math.max(0, Style.cornerRadius - 2)
          color: closeHover.containsMouse ? Util.alpha(root.contentForeground, 0.12) : "transparent"
          anchors.verticalCenter: parent.verticalCenter

          HoverHandler { id: closeHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.close()
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "✕"
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      Text {
        visible: root.statusText !== ""
        width: parent.width
        text: root.statusText
        textFormat: Text.PlainText
        color: root.statusIsError ? Color.urgent : root.contentMuted
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        renderType: Text.NativeRendering
      }

      Row {
        width: parent.width
        spacing: Style.space(12)

        Column {
          width: parent.width * 0.42
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: "New macro"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          TextField {
            id: labelField
            width: parent.width
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            placeholderText: "Name (optional)"
            onAccepted: {
              if (!root.recording) root.save()
            }
            Keys.onPressed: function(event) { root.fieldEscape(event) }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: recordButton
              text: root.recording ? "Cancel" : "Record"
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.recording ? root.cancelRecording() : root.startRecording()
            }

            Rectangle {
              id: recordChip
              width: Math.max(Style.space(40), comboText.implicitWidth + Style.space(16))
              height: recordButton.implicitHeight
              radius: Math.max(0, Style.cornerRadius - 2)
              color: root.recording
                ? Color.urgent
                : (root.comboKeys !== "" ? Util.alpha(Color.accent, 0.18) : Util.alpha(root.contentForeground, 0.08))
              activeFocusOnTab: true
              Keys.onPressed: function(event) { root.recordPressed(event) }

              Text {
                id: comboText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.recording
                  ? (root.heldMods !== "" ? root.heldMods + " …" : "Press keys …")
                  : (root.comboKeys !== "" ? root.comboKeys : "No combo yet")
                color: root.recording ? Color.background : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                renderType: Text.NativeRendering
              }
            }
          }
          }

        Column {
          width: parent.width * 0.56
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: "Text to insert"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          TextField {
            id: phraseField
            width: parent.width
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            placeholderText: "Text to insert, e.g. SUPER DESKTOP"
            onAccepted: {
              if (!root.recording) root.save()
            }
            Keys.onPressed: function(event) { root.fieldEscape(event) }
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: "Save macro"
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.save()
            }

            Button {
              visible: root.comboKeys !== "" || phraseField.text !== "" || labelField.text !== ""
              text: "Clear"
              foreground: root.contentMuted
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: { root.clearForm(); root.setStatus("", false) }
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: root.separator
      }
    }

    // Saved macros: a scrollable table with keyboard navigation.
    Column {
      id: tableColumn
      anchors.top: topColumn.bottom
      anchors.topMargin: Style.space(12)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: footer.top
      anchors.bottomMargin: Style.space(8)
      spacing: Style.space(6)

      Row {
        id: tableHead
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: parent.width * 0.26
          textFormat: Text.PlainText
          text: "COMBO"
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width * 0.24
          textFormat: Text.PlainText
          text: "NAME"
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width - parent.spacing * 2 - ((parent.width * 0.26) + (parent.width * 0.24))
          textFormat: Text.PlainText
          text: "TEXT"
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideRight
        }
      }

      Text {
        visible: root.macros.length === 0
        width: parent.width
        text: "Nothing saved yet. Record a combo on the left, type the phrase, save."
        color: root.contentMuted
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      ListView {
        id: list
        width: parent.width
        height: parent.height - tableHead.height - parent.spacing
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.macros
        spacing: Style.space(2)
        interactive: true
        pixelAligned: true
        maximumFlickVelocity: 1500
        currentIndex: 0

        ScrollIndicator.vertical: ScrollIndicator {}

        delegate: Rectangle {
          required property var modelData
          required property int index
          width: list.width
          height: Math.max(Style.space(36), rowColumn.implicitHeight + Style.space(10))
          radius: Math.max(0, Style.cornerRadius - 2)
          color: list.currentIndex === index
            ? Util.alpha(root.contentForeground, 0.09)
            : (rowHover.hovered ? Util.alpha(root.contentForeground, 0.05) : "transparent")

          Rectangle {
            visible: list.currentIndex === index
            width: 3
            height: parent.height
            radius: 1.5
            color: Color.accent
            anchors.left: parent.left
            anchors.leftMargin: -Style.space(6)
          }

          HoverHandler { id: rowHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { list.currentIndex = index; list.forceActiveFocus() }
            onDoubleClicked: root.runSelected()
          }

          Column {
            id: rowColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(2)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: (list.width - Style.space(46)) * 0.283
                textFormat: Text.PlainText
                text: String(modelData.keys || "")
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
                renderType: Text.NativeRendering
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                width: (list.width - Style.space(46)) * 0.26
                textFormat: Text.PlainText
                text: String(modelData.label || "")
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                renderType: Text.NativeRendering
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                width: (list.width - Style.space(46)) - (list.width - Style.space(46)) * (0.283 + 0.26)
                textFormat: Text.PlainText
                text: String(modelData.text || "")
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                renderType: Text.NativeRendering
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          Rectangle {
            width: Style.space(24)
            height: Style.space(24)
            radius: Math.max(0, Style.cornerRadius - 2)
            color: deleteRowHover.containsMouse ? Util.alpha(root.contentForeground, 0.12) : "transparent"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Style.space(4)

            HoverHandler { id: deleteRowHover }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.deleteMacro(modelData.id)
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "✕"
              color: root.contentMuted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.runSelected()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Delete) {
            root.deleteSelected()
            event.accepted = true
          }
        }
      }
    }

    Column {
      id: footer
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "↑ ↓ select  ·  Enter insert  ·  Del remove  ·  Esc close/cancel  ·  super drag to move"
        color: root.contentMuted
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Timer {
    id: fireDelay
    interval: 180
    onTriggered: root.doFire()
  }

  Timer {
    id: recordTimer
    interval: 10000
    onTriggered: {
      if (!root.recording) return
      root.finishRecording(false, null)
      root.setStatus("Recording timed out — try again", true)
    }
  }

  FileView {
    id: store
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: if (!root.writing) root.apply(text())
    onLoadFailed: if (!root.writing) root.apply("")
    onFileChanged: if (!root.writing) reload()
  }
}
