import QtQuick
import "Model.js" as Model

// One agent's mark in the bar strip. Motion is reserved for states that
// change soon or need you: working breathes, blocked blinks.
Text {
  id: root

  property string status: "idle"
  property string fontFamily: ""
  property int fontSize: 12

  text: Model.GLYPH[status]
  font.family: fontFamily
  font.pixelSize: fontSize
  font.bold: status === "blocked" || status === "ready"
  opacity: status === "idle" || status === "unknown" ? 0.45 : 1
  renderType: Text.NativeRendering

  Behavior on color { ColorAnimation { duration: 200 } }

  SequentialAnimation on opacity {
    running: root.status === "working"
    loops: Animation.Infinite
    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
  }

  SequentialAnimation on opacity {
    running: root.status === "blocked"
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: 80 }
    PauseAnimation { duration: 700 }
    NumberAnimation { to: 0.2; duration: 80 }
    PauseAnimation { duration: 400 }
  }
}
