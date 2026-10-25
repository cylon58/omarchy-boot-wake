import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One switch per fix. Switches and the slider only change a draft; Save
// applies the whole draft with one bin/boot-wake call, so the password is
// asked at most once. Whatever the helper prints back is the real state of
// the machine, and the draft resets to it.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool working: false
  property bool saving: false
  property string message: ""
  property var state: ({})
  property var draft: ({})

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/boot-wake").toString().replace("file://", ""))
  readonly property var fixes: [
    { id: "hibernate-unlock", label: "No second password after hibernate",
      description: "The disk password on wake already proves it's you. Normal sleep still locks." },
    { id: "boot-menu", label: "Shorter boot menu",
      description: "Takes a snapshot first." },
    { id: "dock-wake", label: "Stay awake while docked",
      description: "Lid shut on a dock, it no longer sleeps when the screen locks or just after waking. Undocked, closing the lid still sleeps." }
  ]

  function open() { opened = true; run(["status"]) }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "io.github.cylon58.boot-wake")
    else close()
  }

  function fixState(id) { return state[id] || { enabled: false, blocked: "" } }
  function savedSeconds() { return fixState("boot-menu").seconds || 1 }

  function resetDraft() {
    draft = {
      "hibernate-unlock": fixState("hibernate-unlock").enabled,
      "boot-menu": fixState("boot-menu").enabled,
      "dock-wake": fixState("dock-wake").enabled,
      "seconds": savedSeconds()
    }
  }

  function setDraft(key, value) {
    var next = Object.assign({}, draft)
    next[key] = value
    draft = next
  }

  readonly property bool dirty: {
    var d = draft
    if (d["seconds"] === undefined) return false
    for (var i = 0; i < fixes.length; i++)
      if (!!d[fixes[i].id] !== fixState(fixes[i].id).enabled) return true
    return d["boot-menu"] && d["seconds"] !== savedSeconds()
  }

  function flip(id) {
    if (working) return
    if (!draft[id] && fixState(id).blocked) {
      message = "Can't turn this on: " + fixState(id).blocked + "."
      return
    }
    message = ""
    setDraft(id, !draft[id])
  }

  // Picking a time means wanting the shorter menu, so it switches that on.
  function pickSeconds(seconds) {
    if (working) return
    var next = Object.assign({}, draft)
    next["seconds"] = Math.round(seconds)
    next["boot-menu"] = true
    draft = next
  }

  function save() {
    if (working || !dirty) return
    saving = true
    run(["apply",
         "hibernate-unlock=" + (draft["hibernate-unlock"] ? "on" : "off"),
         "dock-wake=" + (draft["dock-wake"] ? "on" : "off"),
         "boot-menu=" + (draft["boot-menu"] ? String(draft["seconds"]) : "off")])
  }

  function rowDescription(fix) {
    var current = fixState(fix.id)
    if (current.blocked && !current.enabled) return "Unavailable: " + current.blocked + "."
    if (fix.id === "boot-menu") {
      var n = draft["seconds"] || 1
      return "Waits " + n + (n === 1 ? " second" : " seconds") + " instead of 5. " + fix.description
    }
    return fix.description
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
        root.saving = false
        if (exitCode === 0) {
          try { root.state = JSON.parse(out.text) } catch (e) {}
          root.resetDraft()
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
      // Hyprland may tile the window to any size; keep the rows at the top.
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(24)
      spacing: Style.space(12)

      Text {
        text: "Boot & Wake"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title * 1.5
        font.bold: true
        bottomPadding: Style.space(8)
      }

      Repeater {
        model: root.fixes
        delegate: ColumnLayout {
          required property var modelData
          Layout.fillWidth: true
          spacing: Style.space(8)

          StatusToggle {
            Layout.fillWidth: true
            label: modelData.label
            description: root.rowDescription(modelData)
            checked: !!root.draft[modelData.id]
            onClicked: root.flip(modelData.id)
          }

          // How long the boot menu waits, 1 to 5 seconds.
          RowLayout {
            visible: modelData.id === "boot-menu"
            Layout.fillWidth: true
            Layout.leftMargin: Style.spacing.rowPaddingX
            Layout.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.space(16)

            PanelSlider {
              Layout.fillWidth: true
              minimum: 1
              maximum: 5
              step: 1
              integer: true
              tickCount: 5
              value: root.draft["seconds"] || 1
              onMoved: function(v) { root.pickSeconds(v) }
              onReleased: function(v) { root.pickSeconds(v) }
            }

            Text {
              text: (root.draft["seconds"] || 1) + " s"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              Layout.preferredWidth: Style.space(36)
              horizontalAlignment: Text.AlignRight
            }
          }
        }
      }

      // Red while there are unsaved changes, green once the machine matches.
      Rectangle {
        id: saveButton
        readonly property color tone: root.dirty || root.saving ? "#f87171" : "#4ade80"
        Layout.alignment: Qt.AlignRight
        Layout.topMargin: Style.space(4)
        implicitWidth: saveLabel.implicitWidth + Style.space(48)
        implicitHeight: Math.max(36, saveLabel.implicitHeight + Style.space(16))
        radius: Style.cornerRadius
        color: Qt.alpha(tone, saveMouse.containsMouse && root.dirty ? 0.4 : 0.25)
        border.width: 1
        border.color: tone
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
          id: saveLabel
          anchors.centerIn: parent
          text: root.saving ? "Saving…" : (root.dirty ? "Save" : "Saved")
          color: saveButton.tone
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        MouseArea {
          id: saveMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: root.dirty ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.save()
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
