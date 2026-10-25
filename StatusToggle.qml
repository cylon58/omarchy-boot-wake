import QtQuick
import qs.Commons
import qs.Ui

// The shell's Toggle row, except the switch reads green when a fix is on and
// red when it is off. Labels keep the theme's own colours.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool checked: false
  property color onColor: "#4ade80"
  property color offColor: "#f87171"

  // Optional control shown between the text and the switch. It sits above
  // the row's click area, so it keeps its own clicks and drags.
  default property alias accessory: accessorySlot.data

  signal clicked()

  activeFocusOnTab: true
  Keys.onReturnPressed: root.clicked()
  Keys.onEnterPressed: root.clicked()
  Keys.onSpacePressed: root.clicked()

  implicitHeight: Math.max(54, content.implicitHeight + Style.spacing.huge)
  implicitWidth: Style.space(240)
  radius: Style.cornerRadius

  readonly property bool _hot: mouse.containsMouse
  color: Style.controlFill(activeFocus, _hot, Color.foreground, Color.accent)
  borderSpec: Border.controlSpec(activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), Color.foreground, Color.accent)

  Behavior on color { ColorAnimation { duration: 100 } }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX
    z: 1

    Column {
      width: parent.width - track.width - parent.spacing
        - (accessorySlot.width > 0 ? accessorySlot.width + parent.spacing : 0)
      spacing: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: root.label
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: root.description !== ""
        text: root.description
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    Row {
      id: accessorySlot
      anchors.verticalCenter: parent.verticalCenter
    }

    // The row owns the click, so the switch is presentation only here. Drawn
    // here rather than with the shell's ToggleSwitch, which tints the knob
    // toward the theme and washes out the green.
    Rectangle {
      id: track
      readonly property color tone: root.checked ? root.onColor : root.offColor
      width: Math.round(height * 1.9)
      height: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Qt.alpha(tone, 0.25)
      border.width: 1
      border.color: tone
      anchors.verticalCenter: parent.verticalCenter
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        readonly property int inset: 3
        width: parent.height - inset * 2
        height: width
        radius: parent.radius > 0 ? width / 2 : 0
        x: root.checked ? parent.width - width - inset : inset
        anchors.verticalCenter: parent.verticalCenter
        color: track.tone
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
