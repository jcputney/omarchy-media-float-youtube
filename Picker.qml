// Row picker overlay for the media-float tools.
//
// The bash side owns all the logic: it writes a JSON array of rows to a file
// and summons this overlay, which returns exactly one row's opaque `value`
// through a selection file. Every menu level is a separate summon, so this
// stays a dumb "pick one of these" primitive with no idea what Plex or Twitch
// or YouTube are.
//
// Payload: { rowsFile, selectionFile, doneFile, prompt, freeText, backValue }
// Row:     { label, image, info, value }

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by the plugin host.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property var rows: []
  property var filtered: []
  property string selectionFile: ""
  property string doneFile: ""
  property string promptText: "Pick"
  property bool freeText: false
  // What Escape answers with. A menu that has a level above it passes the
  // caller's back sentinel here, so Escape steps up instead of closing. Empty
  // — the default — is the old behaviour: Escape dismisses.
  property string backValue: ""

  // Shares the [menu] surface tokens, so a theme that styles the Omarchy menu
  // styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color muted: Color.menu.text
  property color borderColor: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.menu.selectedBorder
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  function open(payloadJson) {
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = {} }
    root.selectionFile = p.selectionFile || ""
    root.doneFile = p.doneFile || ""
    root.promptText = p.prompt || "Pick"
    root.freeText = p.freeText === true
    root.backValue = p.backValue || ""
    root.filterText = ""
    root.selectedIndex = 0
    root.rows = []
    root.filtered = []
    if (p.rowsFile) {
      rowsProc.command = ["cat", p.rowsFile]
      rowsProc.running = true
    }
    root.opened = true
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  // Always answer the caller. A picker that closes without touching the done
  // file leaves the bash side polling until its timeout, which reads as a hang.
  function finish(value) {
    if (root.doneFile !== "") {
      writer.command = ["sh", "-c",
        "printf '%s' \"$1\" > \"$2\"; : > \"$3\"",
        "sh", value || "", root.selectionFile, root.doneFile]
      writer.running = true
    }
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "")
  }

  function loadRows(text) {
    var parsed = []
    try { parsed = JSON.parse(text || "[]") } catch (e) { parsed = [] }
    root.rows = parsed
    root.rebuild()
    // "← Back" sits first so it is visible without scrolling a long list, but
    // opening on it would make Enter mean "go back". Start on the row below.
    if (root.backValue !== "" && parsed.length > 1
        && parsed[0].value === root.backValue)
      root.selectedIndex = 1
  }

  // Every whitespace-separated term must appear somewhere in the label, which
  // is how fzf's default matching behaves and what the fzf picker did before.
  function rebuild() {
    var q = root.filterText.toLowerCase().trim()
    if (q === "") {
      root.filtered = root.rows
    } else {
      var terms = q.split(/\s+/)
      var out = []
      for (var i = 0; i < root.rows.length; i++) {
        var hay = (root.rows[i].label || "").toLowerCase()
        var ok = true
        for (var t = 0; t < terms.length; t++)
          if (hay.indexOf(terms[t]) === -1) { ok = false; break }
        if (ok) out.push(root.rows[i])
      }
      root.filtered = out
    }
    if (root.selectedIndex >= root.filtered.length)
      root.selectedIndex = Math.max(0, root.filtered.length - 1)
  }

  function move(delta) {
    if (root.filtered.length === 0) return
    var n = root.selectedIndex + delta
    if (n < 0) n = 0
    if (n > root.filtered.length - 1) n = root.filtered.length - 1
    root.selectedIndex = n
    list.positionViewAtIndex(n, ListView.Contain)
  }

  readonly property var current: (root.filtered.length > 0
    && root.selectedIndex < root.filtered.length)
    ? root.filtered[root.selectedIndex] : null

  Process { id: writer }

  Process {
    id: rowsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadRows(text)
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-media-float"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea { anchors.fill: parent; onClicked: root.finish("") }
    }

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: root.opened

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          root.finish(root.backValue); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          // In free-text mode what you typed is the answer; there is nothing
          // to pick from.
          root.finish(root.freeText
            ? root.filterText
            : (root.current ? (root.current.value || "") : ""))
          event.accepted = true
        } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
          root.move(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
          root.move(-1); event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          root.move(10); event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          root.move(-10); event.accepted = true
        } else if (event.key === Qt.Key_Backspace) {
          root.filterText = root.filterText.slice(0, -1)
          root.selectedIndex = 0
          root.rebuild(); event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text >= " ") {
          root.filterText += event.text
          root.selectedIndex = 0
          root.rebuild(); event.accepted = true
        }
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        // Sized from the screen, not a fixed token: Style.space(1100) is a
        // sensible card on a 1080p panel and a postage stamp on a 4K one.
        width: Math.min(Math.max(Style.space(900), parent.width * 0.58),
                        parent.width - Style.gapsOut * 4)
        // A free-text prompt has no list and no preview, so it shrinks to the
        // two lines it actually draws rather than opening as an empty slab.
        height: root.freeText
          ? Style.spacing.panelPadding * 2 + Style.spacing.md
            + Style.font.title + Style.font.body * 2
          : Math.min(Math.max(Style.space(600), parent.height * 0.66),
                     parent.height - Style.gapsOut * 4)
        color: root.background
        radius: root.cornerRadius
        border.color: root.borderColor
        border.width: 1

        Column {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.md

          // Header: prompt, what you have typed, and how much it narrowed to.
          Row {
            width: parent.width
            spacing: Style.spacing.md
            Text {
              text: root.promptText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width - Style.space(220)
              text: root.filterText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
            }
            Text {
              visible: !root.freeText
              text: root.filtered.length + "/" + root.rows.length
              color: root.muted
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Row {
            width: parent.width
            height: parent.height - Style.font.title - Style.spacing.md * 2
            spacing: Style.spacing.lg

            Text {
              visible: root.freeText
              width: parent.width
              text: "Type your search, then press Enter."
              color: root.muted
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            ListView {
              id: list
              visible: !root.freeText
              width: parent.width * 0.52
              height: parent.height
              clip: true
              model: root.filtered
              currentIndex: root.selectedIndex
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                width: list.width
                height: Style.space(30)
                color: index === root.selectedIndex ? root.selectedBackground : "transparent"
                radius: Style.space(4)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.rightMargin: Style.spacing.sm
                  text: modelData.label || ""
                  color: index === root.selectedIndex ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: { root.selectedIndex = index; root.finish(modelData.value || "") }
                }
              }
            }

            // Preview: artwork on top, details underneath.
            Column {
              visible: !root.freeText
              width: parent.width * 0.48 - Style.spacing.lg
              height: parent.height
              spacing: Style.spacing.md

              Image {
                width: parent.width
                height: parent.height * 0.55
                source: (root.current && root.current.image) ? root.current.image : ""
                visible: source != ""
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                horizontalAlignment: Image.AlignLeft
                verticalAlignment: Image.AlignTop
              }

              Text {
                width: parent.width
                text: (root.current && root.current.info) ? root.current.info : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                maximumLineCount: 12
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }
}
