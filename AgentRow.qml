import QtQuick
import qs.Commons

// One agent in the panel: dot · session title · folder · status word.
Item {
  id: root

  property var agent: ({})
  property bool selected: false
  property bool showFolder: true
  property string statusLabel: ""
  property color statusColor: "white"
  property color foreground: "white"
  property color dim: "grey"
  property string fontFamily: ""

  signal hovered()
  signal clicked()

  readonly property bool quiet: agent.status === "idle" || agent.status === "unknown"

  height: title.implicitHeight + Style.space(10)

  Rectangle {
    anchors.fill: parent
    radius: Style.space(4)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.selected ? 0.08 : 0)
    Behavior on color { ColorAnimation { duration: 120 } }
  }

  Rectangle {
    id: dot
    x: Style.space(17)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(5); height: width; radius: width / 2
    color: root.statusColor
  }

  Text {
    id: title
    anchors.left: dot.right
    anchors.leftMargin: Style.space(9)
    anchors.right: folder.visible ? folder.left : status.left
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    text: root.agent.title || ""
    color: root.quiet ? root.dim : root.foreground
    elide: Text.ElideRight
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // Capped so a long folder name can't squeeze the title out.
  Text {
    id: folder
    visible: root.showFolder && text !== ""
    anchors.right: status.left
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.width * 0.3)
    text: root.agent.folderLabel || ""
    color: root.dim
    elide: Text.ElideMiddle
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    id: status
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: root.statusLabel
    color: root.quiet ? root.dim : root.statusColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.agent.status === "blocked"
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: root.hovered()
    onClicked: root.clicked()
  }
}
