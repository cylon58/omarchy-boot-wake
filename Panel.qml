import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One switch per fix. The panel owns no state of its own: every flip runs
// bin/boot-wake, which prints the real state back, so the switches only ever
// show what is actually on the machine.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool working: false
  property string pendingFix: ""
  property string message: ""
  property var state: ({})

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/boot-wake").toString().replace("file://", ""))
  readonly property var fixes: [
    { id: "hibernate-unlock", label: "No second password after hibernate",
      description: "The disk password on wake already proves it's you. Normal sleep still locks." },
    { id: "boot-menu", label: "Shorter boot menu",
      description: "Waits 1 second instead of 5. Asks for your password and takes a snapshot first." }
  ]

  function open() { opened = true; run(["status"]) }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "io.github.cylon58.boot-wake")
    else close()
  }

  function fixState(id) { return state[id] || { enabled: false, blocked: "" } }

  function flip(id) {
    if (working) return
    var current = fixState(id)
    if (!current.enabled && current.blocked) {
      message = "Can't turn this on: " + current.blocked + "."
      return
    }
    pendingFix = id
    run([current.enabled ? "disable" : "enable", id])
  }

  function run(args) {
    working = true
    message = ""
    proc.command = [helper].concat(args)
    proc.running = true
  }

  Process {
    id: proc
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    onExited: function(exitCode) {
      // Collectors can land after the exit signal; read them on the next tick.
      Qt.callLater(function() {
        root.working = false
        root.pendingFix = ""
        if (exitCode === 0) {
          try { root.state = JSON.parse(out.text) } catch (e) {}
          return
        }
        try { root.message = JSON.parse(err.text).error }
        catch (e) { root.message = "Something went wrong. Run boot-wake in a terminal for details." }
        proc.command = [root.helper, "status"]
        proc.running = true
      })
    }
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "Boot & Wake"
    implicitWidth: 520
    implicitHeight: column.implicitHeight + Style.space(48)
    color: Color.background
    onVisibleChanged: if (!visible) root.opened = false

    Shortcut { sequence: "Escape"; onActivated: root.dismiss() }

    ColumnLayout {
      id: column
      anchors.fill: parent
      anchors.margins: Style.space(24)
      spacing: Style.space(12)

      Text {
        text: "Boot & Wake"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Repeater {
        model: root.fixes
        delegate: Toggle {
          required property var modelData
          Layout.fillWidth: true
          label: modelData.label
          description: root.fixState(modelData.id).blocked && !root.fixState(modelData.id).enabled
            ? "Unavailable: " + root.fixState(modelData.id).blocked + "."
            : modelData.description
          checked: root.fixState(modelData.id).enabled
          opacity: root.working && root.pendingFix === modelData.id ? 0.5 : 1
          onClicked: root.flip(modelData.id)
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.message !== ""
        text: root.message
        color: Color.urgent
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
