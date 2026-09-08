// Row picker overlay for the media-float tools.
//
// The bash side owns all the logic: it writes a JSON array of rows to a file
// and summons this overlay, which returns exactly one row's opaque `value`
// through a selection file. Every menu level is a separate summon, so this
// stays a dumb "pick one of these" primitive with no idea what Plex or Twitch
// or YouTube are.
//
// Payload: { rowsFile, selectionFile, doneFile, prompt, freeText, backValue,
//            detail }
// Row:     { label, imageRef, info, value }
//
// Everything in the payload is data. It names files, and it says whether this
// menu has extra facts worth fetching — it never names a program to run. The
// helper argv is built here, out of the plugin directory this file was loaded
// from, so a payload from somewhere else cannot choose what executes. The file
// paths are required to sit under the runtime directory for the same reason.
//
// Row text is remote in origin — video titles, channel names, plot summaries —
// so every sink that renders it is pinned to plain text. Qt's default sniffs
// for HTML, and Qt rich text fetches the resources it finds.

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
  // Whether this menu has facts too slow to bake into every row. When it does,
  // the row the cursor rests on is looked up through the tool's own helper.
  property bool detailEnabled: false
  property var detailCache: ({})
  property string detailText: ""
  property bool detailBusy: false

  // Artwork resolved to a local file, per row.
  property var imageCache: ({})
  property string imagePath: ""

  // Caps. The row file is written by the tool a moment earlier, so this is not
  // where an attack begins — but a parser with no limits is one malformed feed
  // away from holding the whole shell, and the shell is not ours to hang.
  readonly property int maxRows: 5000
  readonly property int maxLabel: 512
  readonly property int maxInfo: 8192
  readonly property int maxValue: 1024
  readonly property int maxDetailChars: 4096
  readonly property int maxRowsBytes: 8388608
  readonly property int helperDeadlineMs: 30000

  // The directory this Picker.qml was loaded from, which is the plugin's own
  // checkout, and the tool that shipped inside it.
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    if (u.indexOf("file://") !== 0) return ""
    u = u.substring(7)
    return u.charAt(u.length - 1) === "/" ? u.substring(0, u.length - 1) : u
  }
  readonly property string toolSlug: {
    var id = (root.manifest && root.manifest.id) || ""
    var i = id.lastIndexOf("-")
    var slug = i < 0 ? "" : id.substring(i + 1)
    return /^[a-z]+$/.test(slug) ? slug : ""
  }
  // Fixed argv, chosen here and never supplied by a caller. The plugin's own
  // copy first; the installed command only as a fallback, and only at a path
  // this file builds itself.
  readonly property string helperPath: {
    if (root.toolSlug === "") return ""
    if (root.pluginDir !== "") return root.pluginDir + "/bin/" + root.toolSlug + "-float"
    var home = Quickshell.env("HOME") || ""
    return home === "" ? "" : home + "/.local/bin/" + root.toolSlug + "-float"
  }

  // A payload may only point at the runtime directory the tools write to.
  function pathAllowed(f) {
    if (!f || f.indexOf("/") !== 0) return false
    if (f.indexOf("..") !== -1) return false
    var rt = Quickshell.env("XDG_RUNTIME_DIR") || ""
    var roots = [rt === "" ? "/tmp/float-overlay/" : rt + "/float-overlay/"]
    for (var i = 0; i < roots.length; i++)
      if (f.indexOf(roots[i]) === 0) return true
    return false
  }

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
    var sel = String(p.selectionFile || "")
    var don = String(p.doneFile || "")
    var rowsFile = String(p.rowsFile || "")
    // Refuse to answer, or read, anywhere but the runtime directory.
    root.selectionFile = root.pathAllowed(sel) ? sel : ""
    root.doneFile = root.pathAllowed(don) ? don : ""
    root.promptText = String(p.prompt || "Pick").substring(0, root.maxLabel)
    root.freeText = p.freeText === true
    root.backValue = String(p.backValue || "").substring(0, root.maxValue)
    root.detailEnabled = p.detail === true
    root.clearDetail()
    root.clearImage()
    root.filterText = ""
    root.selectedIndex = 0
    root.rows = []
    root.filtered = []
    if (rowsFile !== "" && root.pathAllowed(rowsFile)) {
      // head, not cat: the read stops at the ceiling rather than trusting the
      // file to be a sane size. A truncated read parses as no rows, which the
      // bash side sees as a dismissal.
      rowsProc.command = ["head", "-c", String(root.maxRowsBytes), "--", rowsFile]
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
    if (!Array.isArray(parsed)) parsed = []
    if (parsed.length > root.maxRows) parsed = parsed.slice(0, root.maxRows)
    var clean = []
    for (var i = 0; i < parsed.length; i++) {
      var r = parsed[i]
      if (!r || typeof r !== "object") continue
      clean.push({
        label:    String(r.label || "").substring(0, root.maxLabel),
        imageRef: String(r.imageRef || "").substring(0, root.maxValue),
        info:     String(r.info || "").substring(0, root.maxInfo),
        value:    String(r.value || "").substring(0, root.maxValue)
      })
    }
    parsed = clean
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

  onCurrentChanged: { root.refreshDetail(); root.refreshImage() }

  // ── Helper lookups ────────────────────────────────────────────────────────
  // Both lookups run the same fixed argv — the tool that shipped beside this
  // file — with the row's own data as a plain argument. No shell, so nothing in
  // a row can be read as syntax, and no caller can choose the program.

  function clearDetail() {
    detailTimer.stop()
    detailDeadline.stop()
    detailProc.forKey = ""
    detailProc.running = false
    root.detailBusy = false
    root.detailText = ""
    root.detailCache = ({})
  }

  function refreshDetail() {
    detailTimer.stop()
    detailDeadline.stop()
    // Dropping the key first: killing a process still finishes its stream, and
    // that partial output must not be filed under the row we moved on to.
    detailProc.forKey = ""
    detailProc.running = false
    root.detailBusy = false
    var v = (root.current && root.current.value) ? root.current.value : ""
    if (!root.detailEnabled || root.helperPath === "" || v === "") {
      root.detailText = ""
      return
    }
    if (root.detailCache.hasOwnProperty(v)) { root.detailText = root.detailCache[v]; return }
    root.detailText = ""
    detailTimer.restart()
  }

  function clearImage() {
    imageTimer.stop()
    imageDeadline.stop()
    imageProc.forKey = ""
    imageProc.running = false
    root.imagePath = ""
    root.imageCache = ({})
  }

  function refreshImage() {
    imageTimer.stop()
    imageDeadline.stop()
    imageProc.forKey = ""
    imageProc.running = false
    var r = (root.current && root.current.imageRef) ? root.current.imageRef : ""
    if (r === "" || root.helperPath === "") { root.imagePath = ""; return }
    if (root.imageCache.hasOwnProperty(r)) { root.imagePath = root.imageCache[r]; return }
    root.imagePath = ""
    imageTimer.restart()
  }

  Timer {
    id: detailTimer
    // Long enough that holding an arrow key scrolls a list without firing a
    // lookup per row, short enough to feel like it answers the moment you stop.
    interval: 300
    onTriggered: {
      var v = (root.current && root.current.value) ? root.current.value : ""
      if (v === "" || root.helperPath === "" || !root.detailEnabled) return
      detailProc.forKey = v
      detailProc.command = [root.helperPath, "_detail", v]
      root.detailBusy = true
      detailProc.running = true
      detailDeadline.restart()
    }
  }

  Timer {
    id: imageTimer
    // Artwork is cheaper than a detail lookup, so it settles sooner.
    interval: 120
    onTriggered: {
      var r = (root.current && root.current.imageRef) ? root.current.imageRef : ""
      if (r === "" || root.helperPath === "") return
      imageProc.forKey = r
      imageProc.command = [root.helperPath, "_thumb", r]
      imageProc.running = true
      imageDeadline.restart()
    }
  }

  // A helper that never returns would otherwise sit there forever. SIGTERM
  // first so it can clean up its own children, SIGKILL if it will not go.
  Timer {
    id: detailDeadline
    interval: root.helperDeadlineMs
    onTriggered: {
      detailProc.forKey = ""
      root.detailBusy = false
      if (detailProc.running) { detailProc.signal(15); killDetail.restart() }
    }
  }
  Timer {
    id: killDetail
    interval: 2000
    onTriggered: { if (detailProc.running) { detailProc.signal(9); detailProc.running = false } }
  }

  Timer {
    id: imageDeadline
    interval: root.helperDeadlineMs
    onTriggered: {
      imageProc.forKey = ""
      if (imageProc.running) { imageProc.signal(15); killImage.restart() }
    }
  }
  Timer {
    id: killImage
    interval: 2000
    onTriggered: { if (imageProc.running) { imageProc.signal(9); imageProc.running = false } }
  }

  Process {
    id: detailProc
    // The row this lookup was started for. Empty means the answer is stale and
    // belongs nowhere.
    property string forKey: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        detailDeadline.stop()
        killDetail.stop()
        root.detailBusy = false
        if (detailProc.forKey === "") return
        // A picker left open for a long browse would otherwise grow without
        // bound. Starting over costs one lookup, not correctness.
        if (Object.keys(root.detailCache).length > 200) root.detailCache = ({})
        var out = String(text || "").substring(0, root.maxDetailChars)
        root.detailCache[detailProc.forKey] = out
        if (root.current && root.current.value === detailProc.forKey)
          root.detailText = out
        detailProc.forKey = ""
      }
    }
  }

  Process {
    id: imageProc
    property string forKey: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        imageDeadline.stop()
        killImage.stop()
        if (imageProc.forKey === "") return
        // The helper answers with an absolute path inside the thumbnail cache
        // and nothing else. Anything that is not that is treated as no artwork.
        var f = String(text || "").split("\n")[0].trim()
        var ok = f.indexOf("/") === 0 && f.indexOf("..") === -1
                 && f.indexOf("/float-overlay/thumbs/") !== -1
        var url = ok ? "file://" + f : ""
        if (Object.keys(root.imageCache).length > 400) root.imageCache = ({})
        root.imageCache[imageProc.forKey] = url
        if (root.current && root.current.imageRef === imageProc.forKey)
          root.imagePath = url
        imageProc.forKey = ""
      }
    }
  }

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
              textFormat: Text.PlainText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width - Style.space(220)
              text: root.filterText
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
            }
            Text {
              visible: !root.freeText
              text: root.filtered.length + "/" + root.rows.length
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
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
                id: art
                width: parent.width
                height: parent.height * 0.55
                // Always a file:// path the tool fetched under its own limits.
                // A remote URL never reaches this loader, so there is no host
                // to police here and no request this pane can be made to send.
                source: root.imagePath
                visible: source != ""
                asynchronous: true
                cache: true
                // Caps what gets decoded, not just what gets drawn: without it
                // a small file can still expand into an enormous bitmap.
                sourceSize.width: 1024
                sourceSize.height: 1024
                fillMode: Image.PreserveAspectFit
                horizontalAlignment: Image.AlignLeft
                verticalAlignment: Image.AlignTop
              }

              Text {
                width: parent.width
                text: (root.current && root.current.info) ? root.current.info : ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                // Give the description less room when there are details to fit
                // underneath it, so the two share the pane instead of one
                // pushing the other off the card.
                maximumLineCount: root.detailText !== "" ? 7 : 12
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: text !== ""
                text: root.detailText !== "" ? root.detailText
                                             : (root.detailBusy ? "Loading details…" : "")
                textFormat: Text.PlainText
                color: root.muted
                opacity: root.detailBusy ? 0.4 : 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                maximumLineCount: 8
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }
}
