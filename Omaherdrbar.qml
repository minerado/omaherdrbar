import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Shared.js" as Shared

// Bar widget + popup for herdr agents, ranked by what needs you.
//
// Bar: one mark per agent, coloured from the theme palette.
//   ◆ red, blinks: needs you    ◉ green: done, not looked at yet
//   ● blue, pulses: working     ○ faint: idle
// Left-click opens the panel (j/k to move, Enter to jump to the agent);
// right-click jumps to the herdr workspace.
Panel {
  id: root
  moduleName: "ramon.omaherdrbar"
  ipcTarget: "ramon.omaherdrbar"

  // herdr's installer puts it in ~/.local/bin, which is preferred over PATH:
  // an older packaged /usr/bin/herdr can win on the shell's PATH and fails
  // against a newer running server. The `herdrPath` setting overrides both.
  readonly property string herdr: setting("herdrPath", "") || Quickshell.env("HOME") + "/.local/bin/herdr"
  // Shell prefix that leaves the herdr to run in $h, falling back to PATH.
  readonly property string herdrShell: "h='" + herdr + "'; [ -x \"$h\" ] || h=herdr; "
  // herdr's window is found on each poll (herdr-window). The `workspace`
  // setting pins it to a Hyprland workspace instead.
  readonly property int pinnedWorkspace: setting("workspace", 0)
  readonly property string windowScript: Qt.resolvedUrl("herdr-window").toString().replace("file://", "")
  property int herdrWindowWorkspace: -1
  readonly property int herdrWorkspace: pinnedWorkspace > 0 ? pinnedWorkspace : herdrWindowWorkspace

  property bool running: false
  // False until the first successful poll (see Model.build).
  property bool primed: false
  property var memory: ({})
  property string modelSignature: ""
  property var model: ({ agents: [], groups: [], counts: {}, headline: "", mood: "calm" })
  property real now: Date.now()
  property string selectedKey: ""
  property var theme: ({})
  // Latest state change worth announcing; shown in place of the headline
  // for a few seconds. null when idle.
  property var ticker: null

  // On the herdr workspace you can already see what changed, so the widget
  // doesn't announce it.
  readonly property bool looking: herdrWorkspace > 0 && Hyprland.focusedWorkspace !== null
    && Hyprland.focusedWorkspace.id === herdrWorkspace

  onLookingChanged: if (looking) ticker = null

  readonly property var rows: Model.rows(model)

  // ── Options (Model.OPTIONS) ────────────────────────────────────────────
  // Saved to shell.json with `omarchy bar set`; the new value shows at once
  // from optionOverrides until settings catches up when shell.json reloads.
  // Overrides are only dropped when the panel closes: the bar replaces
  // `settings` on relayout, so clearing them on change loops through the
  // headline width.
  property var optionOverrides: ({})
  property bool settingsView: false
  property int settingsIndex: 0

  function option(key) {
    return optionOverrides[key] !== undefined ? optionOverrides[key] : setting(key, true)
  }

  readonly property bool showFolder: option("showFolder")
  readonly property bool showDuration: option("showDuration")
  readonly property bool showIdleInBar: option("showIdleInBar")
  readonly property bool showHeadline: option("showHeadline")

  function toggleOption(key) {
    var value = !option(key)
    var next = Object.assign({}, optionOverrides)
    next[key] = value
    optionOverrides = next
    if (bar) bar.run("omarchy bar set " + moduleName + " " + key + " " + value + " --json >/dev/null")
  }

  function toggleSettings() {
    settingsView = !settingsView
    settingsIndex = 0
  }
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Status colours from the theme's own palette, so accent/urgent clashes
  // (e.g. both pink) don't blur "done" and "needs you".
  function statusColor(status) {
    if (status === "blocked") return theme.red || Color.urgent
    if (status === "ready") return theme.green || Color.accent
    if (status === "working") return theme.blue || foreground
    return dim
  }

  function apply(text) {
    var snapshot
    try {
      snapshot = JSON.parse(text).result.snapshot
    } catch (e) {
      running = false
      return
    }
    now = Date.now()
    var result = Model.build(snapshot, memory, now, primed)
    memory = result.memory
    primed = true
    var signature = Model.signature(result)
    if (signature !== modelSignature) {
      modelSignature = signature
      model = result
    }
    running = true
    // Picked up on the next poll by copies on other monitors.
    if (Shared.openPanel !== null) ticker = null
    var quiet = looking || Shared.openPanel !== null
    var next = Model.nextTicker(ticker, quiet ? [] : result.events, result.agents)
    ticker = next.ticker
    if (next.fresh) tickerTimer.restart()
    if (opened && !rowByKey(selectedKey)) selectedKey = rows.length ? rows[0].key : ""
  }

  // A poke that lands mid-poll would read the old state, so it queues one
  // more poll instead of being dropped.
  property bool refreshQueued: false

  function refresh() {
    if (snapshotProc.running) refreshQueued = true
    else snapshotProc.running = true
    if (pinnedWorkspace <= 0 && !windowProc.running) windowProc.running = true
  }

  function rowByKey(key) {
    for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return rows[i]
    return null
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    var index = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].key === selectedKey) index = i
    selectedKey = rows[Math.max(0, Math.min(rows.length - 1, index + delta))].key
  }

  // Brings herdr to the front: the pinned workspace, else the window found
  // right now, else a new herdr terminal (Omarchy's own launcher). Each
  // dispatch tries the Lua-config syntax, then the legacy one.
  readonly property string showHerdrCommand: pinnedWorkspace > 0
    ? "[ \"$(hyprctl dispatch 'hl.dsp.focus({ workspace = \"" + pinnedWorkspace + "\" })')\" = ok ]"
      + " || hyprctl dispatch workspace " + pinnedWorkspace
    : "addr=$('" + windowScript + "' | cut -d' ' -f1); if [ -n \"$addr\" ]; then"
      + " [ \"$(hyprctl dispatch \"hl.dsp.focus({ window = 'address:$addr' })\")\" = ok ]"
      + " || hyprctl dispatch focuswindow \"address:$addr\";"
      + " else omarchy-launch-terminal-herdr; fi"

  // Close first: the panel loses keyboard focus once the workspace changes,
  // and an open panel left behind can't be dismissed without the mouse.
  function jumpToHerdr() {
    if (!bar) return
    close()
    bar.run(showHerdrCommand)
  }

  function focusAgent(key) {
    if (!key || !bar) return
    close()
    bar.run(herdrShell + "\"$h\" agent focus '" + key + "' >/dev/null; " + showHerdrCommand)
  }

  // Shown whenever herdr answers, even with no agents, so a fresh install
  // doesn't look broken.
  visible: running
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      Shared.openPanel = root
      ticker = null
      refresh()
      selectedKey = rows.length ? rows[0].key : ""
    } else {
      settingsView = false
      optionOverrides = ({})
      if (Shared.openPanel === root) Shared.openPanel = null
    }
  }

  Component.onCompleted: Shared.copies.push(root)

  Component.onDestruction: {
    Shared.copies = Shared.copies.filter(function(c) { return c !== root })
    // A monitor unplugged with its panel open mustn't silence the others forever.
    if (Shared.openPanel === root) Shared.openPanel = null
  }

  FileView {
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.theme = Model.parseColors(text())
  }

  Timer {
    id: tickerTimer
    interval: root.setting("tickerMs", 6000)
    onTriggered: root.ticker = null
  }

  Process {
    id: snapshotProc
    command: ["sh", "-c", root.herdrShell + "exec \"$h\" api snapshot"]
    stdout: StdioCollector {
      onStreamFinished: root.apply(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.running = false
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  // Where herdr's window is, for `looking`. Empty output: no window.
  Process {
    id: windowProc
    command: [root.windowScript]
    stdout: StdioCollector {
      onStreamFinished: {
        var workspace = parseInt(text.trim().split(" ")[1])
        root.herdrWindowWorkspace = isNaN(workspace) ? -1 : workspace
      }
    }
  }

  // herdr's plugin hook (herdr-hook) calls this on every agent event.
  IpcHandler {
    target: "ramon.omaherdrbar-hook"
    function refresh(): void { Shared.refreshAll() }
  }

  Timer {
    interval: root.opened ? 1000 : root.setting("pollMs", 2000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ── Bar ────────────────────────────────────────────────────────────────

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    labelVisible: false
    active: root.opened
    useActiveColor: false
    // Calm = nothing to do; fade back so the bar stays quiet.
    dimmed: root.model.mood === "calm" && !root.opened && !root.ticker
    fixedWidth: strip.implicitWidth + scaledHorizontalMargin * 2
    tooltipText: root.opened ? "" : Model.tooltip(root.model)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.jumpToHerdr()
      else root.toggle()
    }

    Row {
      id: strip
      anchors.centerIn: parent
      spacing: Style.space(6)

      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Repeater {
          model: Model.barAgents(root.model.agents, root.showIdleInBar)

          StatusMark {
            required property var modelData
            status: modelData.status
            color: root.statusColor(modelData.status)
            fontFamily: button.fontFamily
            fontSize: button.fontSize
          }
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        // The ticker is an event, so it shows even with the headline off.
        text: root.ticker ? root.ticker.text : root.showHeadline ? root.model.headline : ""
        color: root.ticker ? root.statusColor(root.ticker.status)
          : root.model.mood === "urgent" ? root.statusColor("blocked")
          : root.model.mood === "attention" ? root.statusColor("ready") : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }

  // ── Panel ──────────────────────────────────────────────────────────────

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (root.settingsView)
          root.settingsIndex = Math.max(0, Math.min(Model.OPTIONS.length - 1, root.settingsIndex + dy))
        else root.moveSelection(dy)
      }
      onActivateRequested: {
        if (root.settingsView) root.toggleOption(Model.OPTIONS[root.settingsIndex].key)
        else root.focusAgent(root.selectedKey)
      }
      // Esc steps back out of settings before it closes the panel.
      onCloseRequested: root.settingsView ? root.toggleSettings() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s") root.toggleSettings()
        else if (t === "g" && !root.settingsView) root.jumpToHerdr()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: parent.width
          spacing: Style.space(14)

          // Header: what's going on overall, in one line.
          Item {
            width: parent.width
            height: headerText.implicitHeight + Style.space(10)

            Text {
              id: headerText
              text: root.settingsView ? "Herdr · settings" : "Herdr"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: headerText.verticalCenter
              spacing: Style.space(12)

              Text {
                visible: !root.settingsView
                anchors.verticalCenter: parent.verticalCenter
                text: root.model.agents.length + (root.model.agents.length === 1 ? " agent" : " agents")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: gear
                anchors.verticalCenter: parent.verticalCenter
                // Nerd Font cog; U+2699 renders as a colour emoji.
                text: "\uf013"
                color: root.settingsView || gearMouse.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: gearMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleSettings()
                }
              }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: 1
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
            }
          }

          // Settings view: one toggle per option.
          Column {
            visible: root.settingsView
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: Model.OPTIONS

              Item {
                id: optionRow
                required property var modelData
                required property int index
                readonly property bool on: root.option(modelData.key)
                readonly property bool selected: root.settingsIndex === index
                width: parent.width
                height: optionLabel.implicitHeight + Style.space(12)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(4)
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, optionRow.selected ? 0.08 : 0)
                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                Text {
                  id: optionLabel
                  x: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: optionRow.modelData.label
                  color: optionRow.on ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: optionRow.on ? "on" : "off"
                  color: optionRow.on ? (root.theme.green || Color.accent) : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: optionRow.on
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.settingsIndex = optionRow.index
                  onClicked: root.toggleOption(optionRow.modelData.key)
                }
              }
            }
          }

          Text {
            visible: !root.settingsView && root.model.agents.length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No agents yet. Start one in herdr."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.settingsView ? [] : root.model.groups

            Column {
              id: group
              required property var modelData
              width: column.width
              spacing: Style.space(4)

              // Group header: dot · name · most urgent fact · size
              Item {
                width: parent.width
                height: groupLabel.implicitHeight

                Rectangle {
                  id: groupDot
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7); height: width; radius: width / 2
                  color: root.statusColor(group.modelData.status)
                }

                Text {
                  id: groupLabel
                  anchors.left: groupDot.right
                  anchors.leftMargin: Style.space(10)
                  text: group.modelData.label
                  color: group.modelData.status === "idle" ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: groupLabel.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    visible: text !== ""
                    text: group.modelData.summary
                    color: root.statusColor(group.modelData.status)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    text: group.modelData.size
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              Repeater {
                model: group.modelData.agents

                AgentRow {
                  required property var modelData
                  width: group.width
                  agent: modelData
                  selected: root.selectedKey === modelData.key
                  showFolder: root.showFolder
                  statusLabel: Model.statusText(modelData, root.now, root.showDuration)
                  statusColor: root.statusColor(modelData.status)
                  foreground: root.foreground
                  dim: root.dim
                  fontFamily: root.fontFamily
                  onHovered: root.selectedKey = modelData.key
                  onClicked: root.focusAgent(modelData.key)
                }
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.settingsView
              ? "j/k move  ·  Enter toggle  ·  Esc back"
              : "j/k move  ·  Enter go  ·  g herdr  ·  s settings  ·  Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
