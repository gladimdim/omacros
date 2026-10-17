import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Omacros.js" as Omacros

// Macro manager: a list of saved phrases with the key combo each one is
// meant for, plus a small form that records a combo and a phrase. Recording
// only captures the combo — wiring it up is one o.bind line the panel hands
// back ready to paste into ~/.config/hypr/bindings.lua.
Panel {
  id: root
  moduleName: "gladimdim.omacros"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
  readonly property string path: Omacros.statePath(home, stateHome)
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentMuted: Qt.darker(contentForeground, 1.4)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var macros: []
  property string rawText: ""
  property bool writing: false

  // Recording state: capture one combo (modifiers + key), not a sequence.
  property bool recording: false
  property string heldMods: ""
  property var comboTokens: []
  property string comboKeys: ""
  property string bindPreview: ""
  property string statusText: ""
  property bool statusIsError: false
  property string pendingFireId: ""

  readonly property bool fieldFocused: labelField.activeFocus || phraseField.activeFocus

  function open() {
    reload()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function reload() {
    store.reload()
  }

  function apply(text) {
    rawText = String(text || "")
    macros = Omacros.parseState(rawText).macros
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
    bindPreview = ""
    labelField.text = ""
    phraseField.text = ""
  }

  function focusField(field) {
    field.forceActiveFocus()
  }

  function startRecording() {
    recording = true
    heldMods = ""
    setStatus("Press the key combo now — hold modifiers first. Esc cancels.", false)
    recordTimer.restart()
    recorder.forceActiveFocus()
  }

  function cancelRecording() {
    finishRecording(false, null)
    setStatus("", false)
  }

  function finishRecording(committed, tokens) {
    recording = false
    heldMods = ""
    recordTimer.stop()
    keyCatcher.forceActiveFocus()
    if (!committed) return
    comboTokens = tokens
    comboKeys = Omacros.displayKeys(tokens)
    refreshBindPreview()
  }

  function refreshBindPreview() {
    if (comboKeys === "") { bindPreview = ""; return }
    bindPreview = Omacros.bindLineFor({ keys: comboKeys, label: labelField.text, id: "<id>" })
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
    bindPreview = Omacros.bindLineFor(result.macro)
    setStatus("Saved. To fire it from the keys, add the binding below to ~/.config/hypr/bindings.lua", false)
  }

  function deleteMacro(id) {
    var result = Omacros.removeMacro(rawText, id)
    if (!result.ok) return
    persist(result.state)
    setStatus("Deleted", false)
  }

  // Fire after the panel is gone, so wtype's text lands in the window the
  // user returns to, not inside this panel.
  function runMacro(id) {
    pendingFireId = String(id || "")
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

  function keysymName(key, text) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(97 + (key - Qt.Key_A))
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(48 + (key - Qt.Key_0))
    var name = specialKeys[key]
    return name || ""
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

  // Esc inside a text field blurs back to the panel, it doesn't close it.
  function fieldEscape(event) {
    if (event.key !== Qt.Key_Escape) return
    if (root.recording) root.cancelRecording()
    keyCatcher.forceActiveFocus()
    event.accepted = true
  }

  function rowHeadline(macro) {
    var keys = String((macro && macro.keys) || "")
    var label = String((macro && macro.label) || "")
    if (label === "") return keys
    return keys + "   " + label
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(Math.min(bodyColumn.implicitHeight, Style.space(440)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.recording || root.fieldFocused
      onCloseRequested: root.close()

      Flickable {
        id: listScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

      Column {
        id: bodyColumn
        width: listScroll.width
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

          Item { width: 1; height: 1 }

          Text {
            textFormat: Text.PlainText
            text: root.macros.length === 0 ? "" : root.macros.length + (root.macros.length === 1 ? " macro" : " macros")
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
          }
        }

        Text {
          visible: root.statusText !== ""
          textFormat: Text.PlainText
          width: parent.width
          text: root.statusText
          color: root.statusIsError ? Color.urgent : root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          renderType: Text.NativeRendering
        }

        PanelSectionHeader {
          width: parent.width
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          text: "New macro"
        }

        TextField {
          id: labelField
          width: parent.width
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          placeholderText: "Name (optional)"
          onTextChanged: root.refreshBindPreview()
          onAccepted: root.save()
          Keys.onPressed: function(event) { root.fieldEscape(event) }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            id: recordButton
            text: root.recording ? "Cancel" : "Record keys"
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.recording ? root.cancelRecording() : root.startRecording()
          }

          Rectangle {
            width: Math.max(Style.space(40), comboText.implicitWidth + Style.space(16))
            height: recordButton.implicitHeight
            radius: Math.max(0, Style.cornerRadius - 2)
            color: root.recording ? Qt.darker(Color.urgent, 1.2) : Util.alpha(root.contentForeground, 0.08)
            focus: root.recording
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

        TextField {
          id: phraseField
          width: parent.width
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          placeholderText: "Text to insert, e.g. SUPER DESKTOP"
          onAccepted: root.save()
          Keys.onPressed: function(event) { root.fieldEscape(event) }
        }

        TextField {
          visible: root.bindPreview !== ""
          width: parent.width
          readOnly: true
          foreground: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          text: root.bindPreview
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Save macro"
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: root.save()
          }

          Button {
            visible: root.comboKeys !== "" || phraseField.text !== ""
            text: "Clear"
            foreground: root.contentMuted
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: { root.clearForm(); root.setStatus("", false) }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        PanelSectionHeader {
          width: parent.width
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          text: "Saved macros"
        }

        Text {
          visible: root.macros.length === 0
          textFormat: Text.PlainText
          width: parent.width
          text: "Nothing saved yet. Record a combo, type the phrase, save."
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.macros

          Rectangle {
            required property var modelData
            width: bodyColumn.width
            height: Math.max(Style.space(40), rowColumn.implicitHeight + Style.space(12))
            radius: Math.max(0, Style.cornerRadius - 2)
            color: rowHover.hovered ? Util.alpha(root.contentForeground, 0.08) : "transparent"

            HoverHandler { id: rowHover }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runMacro(modelData.id)
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
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.rowHeadline(modelData)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                  renderType: Text.NativeRendering
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: String(modelData.text || "")
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                renderType: Text.NativeRendering
              }
            }

            Rectangle {
              id: deleteButton
              width: Style.space(24)
              height: Style.space(24)
              radius: Math.max(0, Style.cornerRadius - 2)
              color: deleteHover.containsMouse ? Util.alpha(root.contentForeground, 0.12) : "transparent"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.space(6)

              HoverHandler { id: deleteHover }

              MouseArea {
                id: deleteArea
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
        }
      }
      }
    }
  }
}
