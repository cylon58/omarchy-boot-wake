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
  property bool reloading: false
  property string message: ""
  property var state: ({})
  property var draft: ({})
  property var images: []
  property bool pickerOpen: false

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/boot-wake").toString().replace("file://", ""))
  readonly property var fixes: [
    { id: "hibernate-unlock", label: "No second password after hibernate",
      description: "The disk password on wake already proves it's you. Normal sleep still locks." },
    { id: "boot-menu", label: "Shorter boot menu",
      description: "Takes a snapshot first." },
    { id: "dock-wake", label: "Stay awake while docked",
      description: "Lid shut on a dock, it no longer sleeps when the screen locks or just after waking. Undocked, closing the lid still sleeps." }
  ]

  function open() {
    opened = true
    pickerOpen = false
    run(["status"])
    imageProc.running = true
  }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "io.github.cylon58.boot-wake")
    else close()
  }

  function fixState(id) { return state[id] || { enabled: false, blocked: "" } }
  function savedSeconds() { return fixState("boot-menu").seconds || 1 }

  // The slider shows 5 (Omarchy's own wait) while the shorter menu is off.
  function sliderSeconds() { return draft["boot-menu"] ? (draft["seconds"] || 1) : 5 }

  function resetDraft() {
    draft = {
      "hibernate-unlock": fixState("hibernate-unlock").enabled,
      "boot-menu": fixState("boot-menu").enabled,
      "dock-wake": fixState("dock-wake").enabled,
      "seconds": savedSeconds(),
      "boot-image": savedImage()
    }
  }

  function savedImage() { return (state["boot-image"] || {}).current || "omarchy" }

  function fileUrl(path) {
    return "file://" + path.split("/").map(encodeURIComponent).join("/")
  }

  function imageById(id) {
    for (var i = 0; i < images.length; i++) if (images[i].id === id) return images[i]
    return null
  }

  // "other" means the boot image was set outside this panel; keep it until
  // the user picks something.
  readonly property bool imageChanged: draft["boot-image"] !== undefined
    && draft["boot-image"] !== "other" && draft["boot-image"] !== savedImage()

  function pickImage(id) {
    if (working) return
    setDraft("boot-image", id)
  }

  function formatSeconds(s) {
    if (s === null || s === undefined) return ""
    if (s >= 60) return Math.floor(s / 60) + " min " + Math.round(s % 60) + " s"
    return (s < 10 ? Math.round(s * 10) / 10 : Math.round(s)) + " s"
  }

  readonly property string bootTimeText: {
    var t = state["boot-time"]
    if (!t || !t.total) return ""
    var parts = ["Last start " + formatSeconds(t.total)]
    if (t.loader !== null) parts.push("boot menu " + formatSeconds(t.loader))
    if (t.kernel !== null) parts.push("password and system " + formatSeconds(t.kernel))
    return parts.join(" · ")
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
    if (imageChanged) return true
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

  // Picking under 5 seconds turns the shorter menu on; 5 is Omarchy's own
  // wait, so picking it turns the fix off.
  function pickSeconds(seconds) {
    if (working) return
    seconds = Math.round(seconds * 2) / 2
    var next = Object.assign({}, draft)
    next["boot-menu"] = seconds < 5
    if (seconds < 5) next["seconds"] = seconds
    draft = next
  }

  // Sends only what the user changed, so a fix changed elsewhere since the
  // panel opened is left alone.
  function save() {
    if (working || !dirty) return
    var args = ["apply"]
    for (var i = 0; i < fixes.length; i++) {
      var id = fixes[i].id
      var on = !!draft[id]
      var changed = on !== fixState(id).enabled
      if (id === "boot-menu" && on && draft["seconds"] !== savedSeconds()) changed = true
      if (!changed) continue
      args.push(id + "=" + (!on ? "off" : (id === "boot-menu" ? String(draft["seconds"]) : "on")))
    }
    // The boot image needs Omarchy's own command, which asks for the password
    // in a terminal; everything in this save then goes through that terminal.
    if (imageChanged) {
      args[0] = "apply-in-terminal"
      args.push("boot-image=" + draft["boot-image"])
    }
    saving = true
    pickerOpen = false
    run(args)
  }

  function rowDescription(fix) {
    var current = fixState(fix.id)
    if (current.blocked && !current.enabled) return "Unavailable: " + current.blocked + "."
    if (fix.id === "boot-menu") {
      if (!draft["boot-menu"]) return "Waits 5 seconds, Omarchy's default. " + fix.description
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
        root.saving = false
        var wasReloading = root.reloading
        root.reloading = false
        if (exitCode === 0) {
          root.working = false
          try { root.state = JSON.parse(out.text) } catch (e) {}
          root.resetDraft()
          return
        }
        if (!wasReloading) {
          try { root.message = JSON.parse(err.text).error }
          catch (e) { root.message = "Something went wrong. Run boot-wake in a terminal for details." }
        }
        // Show the real state after a failure, but retry only once. Stays
        // working until then so Save and the switches can't be used mid-reload.
        if (wasReloading) { root.working = false; return }
        root.reloading = true
        proc.command = [root.helper, "status"]
        proc.running = true
      })
    }
  }

  Process {
    id: openPicturesProc
    command: [root.helper, "open-pictures"]
  }

  Process {
    id: imageProc
    command: [root.helper, "images"]
    stdout: StdioCollector { id: imageOut; waitForEnd: true }
    onExited: Qt.callLater(function() {
      try { root.images = JSON.parse(imageOut.text) } catch (e) { root.images = [] }
    })
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
        delegate: StatusToggle {
          required property var modelData
          Layout.fillWidth: true
          label: modelData.label
          description: root.rowDescription(modelData)
          checked: !!root.draft[modelData.id]
          onClicked: root.flip(modelData.id)

          // How long the boot menu waits, 1 to 5 seconds.
          Row {
            visible: modelData.id === "boot-menu"
            width: visible ? implicitWidth : 0
            spacing: Style.space(12)

            PanelSlider {
              width: Style.space(220)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 1
              maximum: 5
              step: 0.5
              tickCount: 9
              value: root.sliderSeconds()
              onMoved: function(v) { root.pickSeconds(v) }
              onReleased: function(v) { root.pickSeconds(v) }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.sliderSeconds() + " s"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              width: Style.space(44)
              horizontalAlignment: Text.AlignRight
            }
          }
        }
      }

      // The picture above the disk password box. Opens a grid to pick from.
      BorderSurface {
        id: imageRow
        Layout.fillWidth: true
        implicitHeight: Math.max(54, imageRowContent.implicitHeight + Style.spacing.huge)
        radius: Style.cornerRadius
        readonly property bool _hot: imageMouse.containsMouse
        color: Style.controlFill(false, _hot, Color.foreground, Color.accent)
        borderSpec: Border.controlSpec(_hot ? "hover-cursor" : "normal", Color.foreground, Color.accent)

        Row {
          id: imageRowContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: imageRow.borderLeft + Style.spacing.rowPaddingX
          anchors.rightMargin: imageRow.borderRight + Style.spacing.rowPaddingX
          spacing: Style.spacing.rowPaddingX

          Column {
            width: parent.width - thumb.width - parent.spacing
            spacing: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter

            Text {
              text: "Boot image"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "The picture above the password box at startup. Saving a new one opens a terminal for your password."
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            id: thumb
            width: Style.space(120)
            height: Style.space(40)
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.darker(Color.background, 1.3)
            border.width: 1
            border.color: root.imageChanged ? "#f87171" : Qt.darker(Color.foreground, 2)

            Image {
              anchors.fill: parent
              anchors.margins: 4
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              sourceSize.width: 240
              source: {
                var img = root.imageById(root.draft["boot-image"])
                return root.fileUrl(img ? img.path : "/usr/share/plymouth/themes/omarchy/logo.png")
              }
            }
          }
        }

        MouseArea {
          id: imageMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.pickerOpen = !root.pickerOpen
            // Pick up pictures added to the folder since the last look.
            if (root.pickerOpen) imageProc.running = true
          }
        }
      }

      Flow {
        visible: root.pickerOpen
        Layout.fillWidth: true
        spacing: Style.space(8)

        Repeater {
          model: root.images
          delegate: Rectangle {
            required property var modelData
            readonly property bool chosen: root.draft["boot-image"] === modelData.id
            width: Style.space(118)
            height: Style.space(84)
            color: Qt.darker(Color.background, 1.3)
            border.width: chosen ? 2 : 1
            border.color: chosen ? "#4ade80" : (tileMouse.containsMouse ? Color.accent : Qt.darker(Color.foreground, 2))

            Image {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: 6
              height: parent.height - tileLabel.height - 16
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              sourceSize.width: 220
              source: root.fileUrl(modelData.path)
            }

            Text {
              id: tileLabel
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: 4
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideMiddle
              text: modelData.label
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: tileMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pickImage(modelData.id)
            }
          }
        }

        // Opens ~/Pictures/Boot, where your own boot pictures go.
        Rectangle {
          width: Style.space(118)
          height: Style.space(84)
          color: Qt.darker(Color.background, 1.3)
          border.width: 1
          border.color: addMouse.containsMouse ? Color.accent : Qt.darker(Color.foreground, 2)

          Column {
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "+"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title * 1.5
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Add your own"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: addMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: openPicturesProc.running = true
          }
        }
      }

      Text {
        visible: root.pickerOpen
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "Your own pictures go in Pictures/Boot. Big ones are shrunk to fit; a transparent PNG looks best. Reopen this list to see new ones."
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        spacing: Style.space(16)

        Text {
          Layout.fillWidth: true
          text: root.bootTimeText
          color: Qt.darker(Color.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

      // Red while there are unsaved changes, green once the machine matches.
      Rectangle {
        id: saveButton
        readonly property color tone: root.dirty || root.saving ? "#f87171" : "#4ade80"
        Layout.alignment: Qt.AlignRight
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
