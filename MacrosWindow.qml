import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Omacros.js" as Omacros

// Macro manager in a detached, resizable window: a real toplevel
// (Quickshell FloatingWindow), not a bar popup, so it keeps its size
// (default 60% of screen) however its content changes and can be moved and
// resized like any window. Service.qml asks Hyprland to float, center and
// pin it via a runtime window rule.
FloatingWindow {
  id: root

  property var bar: null
  property var settings: null
  property var hostWidget: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
  readonly property string path: Omacros.statePath(home, stateHome)
  readonly property string imagesDir: Omacros.imagesDir(home, stateHome)
  // The window is a popup-style surface, so it pairs popup colors with the
  // shell font. The inline components below use the same tokens directly
  // (they can't see this scope).
  readonly property color contentForeground: Color.popups.text
  readonly property color contentMuted: Qt.darker(contentForeground, 1.4)
  readonly property string contentFontFamily: Style.font.family
  readonly property color surface: Color.popups.background
  readonly property color separator: Util.alpha(contentForeground, 0.1)
  readonly property color panelBorder: Util.alpha(contentForeground, 0.16)
  readonly property int pad: Style.space(18)

  readonly property bool opened: root.visible
  // First-open size: 60% of the target screen. Binding implicit size lets the
  // window map at that size; once the user (or a rule) resizes it, the width /
  // height pair is written explicitly and this binding stops driving it, so a
  // user's own size wins for the rest of the session.
  implicitWidth: Math.round((root.screen ? root.screen.width : 1920) * 0.6)
  implicitHeight: Math.round((root.screen ? root.screen.height : 1080) * 0.6)
  minimumSize: Qt.size(760, 600)

  property var macros: []
  property string rawText: ""
  property bool writing: false
  property bool recording: false
  property string heldMods: ""
  property var comboTokens: []
  property string comboKeys: ""
  // When set, the form is editing this macro id instead of creating one.
  property string editingId: ""
  // What the form inserts: "text" (phraseField) or "image" (a picked file,
  // already copied into imagesDir as imageName).
  property string formKind: "text"
  property string imageName: ""
  property string imageMime: ""
  property bool importing: false
  property string statusText: ""
  property bool statusIsError: false
  property string pendingFireId: ""

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

  // Size comes from the screen binding; opening just activates + focuses so
  // keyboard control lands in the list right away.
  function welcomed() {
    root.contentItem.forceActiveFocus()
    list.forceActiveFocus()
    reload()
  }

  Timer {
    id: showDelay
    interval: 150
    onTriggered: root.visible = true
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
    editingId = ""
    comboTokens = []
    comboKeys = ""
    heldMods = ""
    labelField.text = ""
    phraseField.text = ""
    formKind = "text"
    imageName = ""
    imageMime = ""
  }

  function imageUrl(name) {
    var path = Omacros.imagePathFor(imagesDir, name)
    return path ? "file://" + path : ""
  }

  function chooseImage() {
    if (importing) return
    if (recording) cancelRecording()
    imageDialog.open()
  }

  // The picked file is copied into imagesDir right away (type checked by its
  // content), so the macro keeps working if the original moves. Saving the
  // form is what makes a macro reference it.
  function importImage(url) {
    var command = Omacros.importCommand(Omacros.localPathFromUrl(url), imagesDir, Omacros.newId())
    if (!command) { setStatus("Can't read that file", true); return }
    importing = true
    setStatus("Importing image …", false)
    importProc.command = command
    importProc.running = true
  }

  function finishImport(exitCode, stdout) {
    importing = false
    var result = Omacros.parseImport(exitCode, stdout)
    if (!result.ok) { setStatus(result.error, true); return }
    imageName = result.image
    imageMime = result.mime
    setStatus("Image ready — " + (editingId !== "" ? "press Update" : "record a combo and save"), false)
  }

  // Clicking a saved row loads it into the form: combo, label and phrase
  // become editable, Save turns into Update. The list selection follows.
  function populateFrom(macro) {
    if (!macro) return
    // Delegate modelData can wrap tokens as a QML model instead of a JS
    // array. Load the original state entry so saving keeps a valid combo.
    macro = Omacros.findMacro(root.macros, macro.id)
    if (!macro) return
    if (recording) cancelRecording()
    editingId = macro.id
    comboTokens = macro.tokens || []
    comboKeys = String(macro.keys || "")
    labelField.text = String(macro.label || "")
    formKind = macro.kind === "image" ? "image" : "text"
    phraseField.text = formKind === "text" ? String(macro.text || "") : ""
    imageName = formKind === "image" ? String(macro.image || "") : ""
    imageMime = formKind === "image" ? String(macro.mime || "") : ""
    selectMacro(macro.id)
    setStatus("Editing " + (comboKeys || "macro") + " — change it and press Update macro, or Cancel edit for a new one", false)
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
    if (importing) { setStatus("Still importing the image — one moment", true); return }
    var input = {
      label: labelField.text,
      tokens: comboTokens,
      kind: formKind,
      text: phraseField.text,
      image: imageName,
      mime: imageMime
    }
    if (editingId !== "") {
      var updated = Omacros.updateMacro(rawText, editingId, input)
      if (!updated.ok) { setStatus(updated.error, true); return }
      persist(updated.state)
      populateFrom(updated.macro)
      setStatus("Updated. " + updated.macro.keys + " fires the new " + (updated.macro.kind === "image" ? "image" : "text") + " everywhere — the combo re-wires itself automatically.", false)
      return
    }
    var result = Omacros.addMacro(rawText, input)
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
    if (editingId === id) { clearForm(); setStatus("Deleted the macro you were editing — form cleared", false) }
    else setStatus("Deleted", false)
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
  // took it: it closes first so the paste lands there, not in the form.
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

  // ---- Building blocks ------------------------------------------------------

  // A bordered card: tinted header strip with a caption, body below.
  component Card: Rectangle {
    id: card
    property string caption: ""
    property string detail: ""
    default property alias body: cardBody.data
    readonly property real headerHeight: cardHeader.height
    color: Util.alpha(Color.popups.text, 0.035)
    border.width: 1
    border.color: Util.alpha(Color.popups.text, 0.16)
    radius: Style.cornerRadius
    clip: true

    Rectangle {
      id: cardHeader
      width: parent.width
      height: Style.space(34)
      color: Util.alpha(Color.popups.text, 0.06)

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: card.caption
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: card.detail
        color: Qt.darker(Color.popups.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Util.alpha(Color.popups.text, 0.16)
      }
    }

    Item {
      id: cardBody
      anchors.top: cardHeader.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
    }
  }

  // Label column + control slot, so every form row lines up on one edge.
  component FormRow: Item {
    id: formRow
    property string label: ""
    property bool topAligned: false
    default property alias content: slot.data
    width: parent ? parent.width : 0
    height: Math.max(rowLabel.implicitHeight, slot.childrenRect.height)

    Text {
      id: rowLabel
      width: Style.space(96)
      y: formRow.topAligned ? Style.space(8) : (formRow.height - height) / 2
      textFormat: Text.PlainText
      text: formRow.label
      color: Qt.darker(Color.popups.text, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignRight
      rightPadding: Style.space(14)
    }

    Item {
      id: slot
      x: Style.space(96)
      width: formRow.width - Style.space(96)
      height: childrenRect.height
    }
  }

  // One key of a combo, drawn as a keycap.
  component KeyCap: Rectangle {
    property string label: ""
    property bool compact: false
    width: capText.implicitWidth + Style.space(compact ? 10 : 14)
    height: capText.implicitHeight + Style.space(compact ? 4 : 6)
    radius: Style.cornerRadius
    color: Util.alpha(Color.popups.text, 0.07)
    border.width: 1
    border.color: Util.alpha(Color.popups.text, 0.24)

    Text {
      id: capText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: parent.compact ? Style.font.caption : Style.font.bodySmall
      font.bold: true
      renderType: Text.NativeRendering
    }
  }

  // Small all-caps pill: macro type in the list, counts in headers.
  component Badge: Rectangle {
    property string label: ""
    property color tint: Color.popups.text
    width: badgeText.implicitWidth + Style.space(12)
    height: badgeText.implicitHeight + Style.space(4)
    radius: Style.cornerRadius
    color: Util.alpha(tint, 0.12)
    border.width: 1
    border.color: Util.alpha(tint, 0.35)

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: parent.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  function capLabel(token) {
    var text = String(token || "")
    return text.length === 1 ? text.toUpperCase() : text
  }

  Item {
    id: content
    anchors.fill: parent
    anchors.margins: root.pad

    // Esc here closes the window; anything that wants it (fields, recorder)
    // accepts the event first.
    Keys.onPressed: function(event) {
      if (event.key !== Qt.Key_Escape) return
      if (root.recording) { root.cancelRecording(); return }
      root.close()
      event.accepted = true
    }

    // ---- Header ------------------------------------------------------------
    Item {
      id: header
      width: parent.width
      height: Style.space(40)

      Rectangle {
        id: logo
        width: Style.space(36)
        height: Style.space(36)
        anchors.verticalCenter: parent.verticalCenter
        radius: Style.cornerRadius
        color: Util.alpha(Color.accent, 0.16)
        border.width: 1
        border.color: Util.alpha(Color.accent, 0.5)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "󰌌"
          color: Color.accent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.iconLarge
        }
      }

      Column {
        anchors.left: logo.right
        anchors.leftMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: "Omacros"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: "Text and image macros · combos wire themselves up"
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "✕"
        tooltipText: "Close (Esc)"
        bordered: true
        foreground: root.contentMuted
        accent: Color.accent
        fontFamily: root.contentFontFamily
        onClicked: root.close()
      }
    }

    // ---- Editor ------------------------------------------------------------
    Card {
      id: editor
      anchors.top: header.bottom
      anchors.topMargin: Style.space(14)
      width: parent.width
      height: headerHeight + form.implicitHeight + root.pad * 2
      caption: root.editingId !== "" ? "EDITING MACRO" : "NEW MACRO"
      detail: root.editingId !== "" ? "changes apply to " + root.comboKeys : "record a combo, choose what it inserts, save"

      Column {
        id: form
        x: root.pad
        y: root.pad
        width: parent.width - root.pad * 2
        spacing: Style.space(12)

        FormRow {
          label: "Name"

          TextField {
            id: labelField
            width: parent.width
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            placeholderText: "Optional, e.g. Signature"
            onAccepted: {
              if (!root.recording) root.save()
            }
            Keys.onPressed: function(event) { root.fieldEscape(event) }
          }
        }

        FormRow {
          label: "Combo"

          Row {
            spacing: Style.space(8)

            Rectangle {
              id: recordChip
              width: Math.max(Style.space(220), comboCaps.width + Style.space(20))
              height: recordButton.height
              radius: Style.cornerRadius
              color: root.recording ? Util.alpha(Color.urgent, 0.18) : Util.alpha(root.contentForeground, 0.04)
              border.width: 1
              border.color: root.recording ? Color.urgent
                : (activeFocus ? Color.accent : root.panelBorder)
              activeFocusOnTab: true
              Keys.onPressed: function(event) { root.recordPressed(event) }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.recording ? root.cancelRecording() : root.startRecording()
              }

              Row {
                id: comboCaps
                visible: !root.recording && root.comboTokens.length > 0
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Repeater {
                  model: root.comboTokens

                  KeyCap {
                    required property var modelData
                    label: root.capLabel(modelData)
                  }
                }
              }

              Text {
                visible: !comboCaps.visible
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.recording
                  ? (root.heldMods !== "" ? root.heldMods + " + …" : "Press the combo now …")
                  : "Not recorded"
                color: root.recording ? Color.urgent : root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: !root.recording
              }
            }

            Button {
              id: recordButton
              text: root.recording ? "Cancel" : (root.comboTokens.length > 0 ? "Re-record" : "Record")
              iconText: root.recording ? "✕" : "●"
              bordered: true
              foreground: root.recording ? Color.urgent : root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.recording ? root.cancelRecording() : root.startRecording()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "hold modifiers, then tap a key · Esc cancels"
              color: root.contentMuted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        FormRow {
          label: "Inserts"

          // Segmented switch: one bordered strip, two halves.
          Rectangle {
            width: kindRow.width + 2
            height: kindRow.height + 2
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.panelBorder

            Row {
              id: kindRow
              x: 1
              y: 1

              Button {
                width: Style.space(96)
                text: "Text"
                iconText: "󰊄"
                selected: root.formKind === "text"
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                onClicked: root.formKind = "text"
              }

              Rectangle { width: 1; height: parent.height; color: root.panelBorder }

              Button {
                width: Style.space(96)
                text: "Image"
                iconText: "󰋩"
                selected: root.formKind === "image"
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                onClicked: root.formKind = "image"
              }
            }
          }
        }

        FormRow {
          visible: root.formKind === "text"
          label: "Text"

          TextField {
            id: phraseField
            width: parent.width
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            placeholderText: "What the combo pastes, e.g. SUPER DESKTOP"
            onAccepted: {
              if (!root.recording) root.save()
            }
            Keys.onPressed: function(event) { root.fieldEscape(event) }
          }
        }

        FormRow {
          visible: root.formKind === "image"
          label: "Image"
          topAligned: true

          Rectangle {
            width: parent.width
            height: Style.space(92)
            radius: Style.cornerRadius
            color: Util.alpha(root.contentForeground, 0.03)
            border.width: 1
            border.color: root.panelBorder

            Rectangle {
              id: previewBox
              x: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(120)
              height: parent.height - Style.space(20)
              radius: Style.cornerRadius
              color: Util.alpha(root.contentForeground, 0.06)
              border.width: 1
              border.color: Util.alpha(root.contentForeground, 0.12)
              clip: true

              Image {
                anchors.fill: parent
                anchors.margins: 3
                source: root.imageUrl(root.imageName)
                sourceSize.height: Style.space(144)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
              }

              Text {
                visible: root.imageName === ""
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "󰋩"
                color: Util.alpha(root.contentForeground, 0.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.displayLarge
              }
            }

            Column {
              anchors.left: previewBox.right
              anchors.leftMargin: Style.space(14)
              anchors.right: chooseButton.left
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.importing ? "Importing …"
                  : (root.imageName !== "" ? root.imageMime.replace("image/", "").toUpperCase() + " image ready" : "No image chosen")
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.imageName !== ""
                  ? "The combo puts it on the clipboard and pastes it into the focused app."
                  : "PNG, JPEG, GIF, WebP or BMP, up to 20 MB. A copy is kept, so the original can move."
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Button {
              id: chooseButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: root.imageName !== "" ? "Replace…" : "Choose image…"
              iconText: "󰉋"
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.chooseImage()
            }
          }
        }

        // Status on the left, actions on the right, one line under the form.
        FormRow {
          label: ""

          Item {
            width: parent.width
            height: saveButton.height

            Rectangle {
              visible: root.statusText !== ""
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              height: Math.max(saveButton.height, statusLine.implicitHeight + Style.space(8))
              radius: Style.cornerRadius
              color: Util.alpha(root.statusIsError ? Color.urgent : Color.accent, 0.1)

              Rectangle {
                width: 3
                height: parent.height
                color: root.statusIsError ? Color.urgent : Color.accent
              }

              Text {
                id: statusLine
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.statusText
                color: root.statusIsError ? Color.urgent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }
            }

            Row {
              id: actions
              anchors.right: parent.right
              spacing: Style.space(8)

              Button {
                visible: root.editingId !== "" || root.comboKeys !== "" || phraseField.text !== "" || labelField.text !== "" || root.imageName !== ""
                text: root.editingId !== "" ? "Cancel edit" : "Clear"
                foreground: root.contentMuted
                accent: Color.accent
                fontFamily: root.contentFontFamily
                onClicked: { root.clearForm(); root.setStatus("", false) }
              }

              Button {
                id: saveButton
                text: root.editingId !== "" ? "Update macro" : "Save macro"
                iconText: "󰆓"
                bordered: true
                selected: true
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                onClicked: root.save()
              }
            }
          }
        }
      }
    }

    // ---- Saved macros --------------------------------------------------------
    Card {
      id: library
      anchors.top: editor.bottom
      anchors.topMargin: Style.space(14)
      anchors.bottom: footer.top
      anchors.bottomMargin: Style.space(12)
      width: parent.width
      caption: "SAVED MACROS · " + root.macros.length
      detail: "click a row to edit · double-click to insert"

      // Shared column geometry for the head row and every list row.
      readonly property real rowPad: Style.space(14)
      readonly property real gap: Style.space(12)
      readonly property real innerWidth: width - rowPad * 2
      readonly property real comboWidth: Math.round(innerWidth * 0.28)
      readonly property real nameWidth: Math.round(innerWidth * 0.18)
      readonly property real typeWidth: Style.space(64)
      readonly property real deleteWidth: Style.space(28)
      readonly property real insertsWidth: innerWidth - comboWidth - nameWidth - typeWidth - deleteWidth - gap * 4

      Rectangle {
        id: tableHead
        width: parent.width
        height: Style.space(28)
        color: Util.alpha(root.contentForeground, 0.025)

        Row {
          x: library.rowPad
          height: parent.height
          spacing: library.gap

          Repeater {
            model: [
              { title: "COMBO", width: library.comboWidth },
              { title: "NAME", width: library.nameWidth },
              { title: "TYPE", width: library.typeWidth },
              { title: "INSERTS", width: library.insertsWidth }
            ]

            Text {
              required property var modelData
              width: modelData.width
              height: parent.height
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: modelData.title
              color: root.contentMuted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: root.separator
        }
      }

      Column {
        visible: root.macros.length === 0
        anchors.centerIn: list
        spacing: Style.space(6)

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: "󰌌"
          color: Util.alpha(root.contentForeground, 0.25)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.displayLarge
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: "No macros yet"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: "Record a combo above, type a phrase or choose an image, then save."
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ListView {
        id: list
        anchors.top: tableHead.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.macros
        interactive: true
        pixelAligned: true
        maximumFlickVelocity: 1500
        currentIndex: 0

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool current: list.currentIndex === index
          readonly property bool isImage: modelData.kind === "image"
          width: list.width
          height: Style.space(isImage ? 52 : 44)
          color: current
            ? Util.alpha(Color.accent, 0.1)
            : (rowHover.hovered ? Util.alpha(root.contentForeground, 0.04) : "transparent")

          HoverHandler { id: rowHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.populateFrom(row.modelData); list.forceActiveFocus() }
            onDoubleClicked: root.runSelected()
          }

          Rectangle {
            visible: row.current
            width: 3
            height: parent.height
            color: Color.accent
          }

          Row {
            x: library.rowPad
            height: parent.height
            spacing: library.gap

            Item {
              width: library.comboWidth
              height: parent.height
              clip: true

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Repeater {
                  model: row.modelData.tokens || []

                  KeyCap {
                    required property var modelData
                    compact: true
                    label: root.capLabel(modelData)
                  }
                }
              }
            }

            Text {
              width: library.nameWidth
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: String(row.modelData.label || "") || "—"
              color: row.modelData.label ? root.contentForeground : root.contentMuted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              renderType: Text.NativeRendering
            }

            Item {
              width: library.typeWidth
              height: parent.height

              Badge {
                anchors.verticalCenter: parent.verticalCenter
                label: row.isImage ? "IMAGE" : "TEXT"
                tint: row.isImage ? Color.accent : root.contentMuted
              }
            }

            Item {
              width: library.insertsWidth
              height: parent.height

              Rectangle {
                id: thumbFrame
                visible: row.isImage
                width: visible ? Style.space(56) : 0
                height: Style.space(38)
                anchors.verticalCenter: parent.verticalCenter
                radius: Style.cornerRadius
                color: Util.alpha(root.contentForeground, 0.06)
                border.width: 1
                border.color: Util.alpha(root.contentForeground, 0.14)
                clip: true

                Image {
                  anchors.fill: parent
                  anchors.margins: 2
                  source: row.isImage ? root.imageUrl(row.modelData.image) : ""
                  sourceSize.height: Style.space(76)
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }
              }

              Text {
                anchors.left: thumbFrame.right
                anchors.leftMargin: row.isImage ? Style.space(10) : 0
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.isImage
                  ? String(row.modelData.mime || "").replace("image/", "").toUpperCase() + " image"
                  : String(row.modelData.text || "")
                color: row.isImage ? root.contentMuted : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                renderType: Text.NativeRendering
              }
            }

            Button {
              width: library.deleteWidth
              anchors.verticalCenter: parent.verticalCenter
              opacity: row.current || rowHover.hovered ? 1 : 0
              iconText: "✕"
              tooltipText: "Delete (Del)"
              foreground: root.contentMuted
              accent: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.deleteMacro(row.modelData.id)
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            x: library.rowPad
            width: parent.width - library.rowPad * 2
            height: 1
            color: root.separator
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

    // ---- Key hints -----------------------------------------------------------
    Row {
      id: footer
      anchors.bottom: parent.bottom
      spacing: Style.space(16)

      Repeater {
        model: [
          { keys: "↑ ↓", what: "select" },
          { keys: "Enter", what: "insert" },
          { keys: "Del", what: "remove" },
          { keys: "Esc", what: "close / cancel" }
        ]

        Row {
          required property var modelData
          spacing: Style.space(6)

          KeyCap {
            compact: true
            label: parent.modelData.keys
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: parent.modelData.what
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  FileDialog {
    id: imageDialog
    title: "Omacros — choose an image"
    nameFilters: Omacros.imageNameFilters
    onAccepted: root.importImage(selectedFile)
  }

  // Exit code and stdout can land in either order; finish once both have.
  property var importExit: null
  property var importText: null

  function importSettled() {
    if (importExit === null || importText === null) return
    var code = importExit
    var text = importText
    importExit = null
    importText = null
    finishImport(code, text)
  }

  Process {
    id: importProc
    onStarted: { root.importExit = null; root.importText = null }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.importText = String(text || ""); root.importSettled() }
    }
    onExited: function(exitCode) {
      root.importExit = exitCode
      root.importSettled()
    }
  }

  Timer {
    id: fireDelay
    interval: 240
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
