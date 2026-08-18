pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "./components"

// Bar widget and popup for a UniFi Network controller.
//
// All network work happens in unifi-fetch, which prints the normalized model
// on stdout and reports failures as {"error":…} rather than dying, so the panel
// can always render a reason. Nothing here ever touches the API key.
Panel {
  id: root

  readonly property string pluginId: "hegjon.unifi"

  moduleName: pluginId
  ipcTarget: pluginId

  // --- state ------------------------------------------------------------

  property var devices: []
  property var site: ({ id: "", name: "" })
  property var gateway: null

  // WAN rate samples for the graph, oldest first: {t, rx, tx}. One entry per
  // controller heartbeat, so consecutive polls that see the same heartbeat
  // add nothing — the rates would just be repeated. Capped so a shell that
  // has been up for a week does not drag a week of points into every paint.
  property var rateHistory: []
  property string lastHeartbeatAt: ""
  readonly property int rateHistoryCap: 120
  property var summary: ({ devices: 0, online: 0, offline: 0, busy: 0, updatable: 0, clients: 0, wired: 0, wireless: 0, vpn: 0 })
  property string lastError: ""
  property bool needsLogin: false
  property bool initialized: false
  property bool refreshing: false
  property real lastUpdatedAt: 0

  // Notification bookkeeping, keyed by device id: what each device looked
  // like last poll, so only genuine transitions announce themselves.
  property var lastSeenById: ({})
  property var notifiedAt: ({})

  // --- settings ---------------------------------------------------------

  // `omarchy bar set` stores booleans as strings unless given --json, so a
  // boolean setting has to be coerced rather than read straight through.
  function boolSetting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property bool showBarClients: boolSetting("showBarClients", false)
  readonly property bool showGatewayStats: boolSetting("showGatewayStats", true)
  readonly property int refreshIntervalMs: intSetting("refreshIntervalSec", 30, 10, 300) * 1000
  readonly property bool watchEnabled: boolSetting("watch", true)
  readonly property int watchIntervalMs: intSetting("watchIntervalSec", 120, 30, 3600) * 1000
  readonly property bool notifyOffline: boolSetting("notifyOffline", true)
  readonly property bool notifyOnline: boolSetting("notifyOnline", true)
  readonly property int notifyCooldownMs: intSetting("notifyCooldownMin", 10, 1, 240) * 60000

  // Qt.resolvedUrl yields a file:// URL; Process wants a plain path.
  readonly property string backendPath:
    Qt.resolvedUrl("unifi-fetch").toString().replace(/^file:\/\//, "")

  readonly property string loginPath:
    Qt.resolvedUrl("unifi-login").toString().replace(/^file:\/\//, "")

  // The bar shows the Ubiquiti mark (components/UbiquitiIcon.qml) rather than
  // a font glyph, so it cannot be confused with the shell's own network widget.
  // The glyph below is only the fallback text should the icon fail to load.
  readonly property string barGlyph: String.fromCodePoint(0xF0002)   // md-access_point_network

  // --- formatting -------------------------------------------------------

  function kindGlyph(kind) {
    switch (kind) {
      case "ap": return String.fromCodePoint(0xF0003)        // md-access_point
      case "switch": return String.fromCodePoint(0xF0318)    // md-lan_connect
      default: return String.fromCodePoint(0xF1087)          // md-router_network
    }
  }

  function stateLabel(state) {
    switch (state) {
      case "ONLINE": return "Online"
      case "OFFLINE": return "Offline"
      case "CONNECTION_INTERRUPTED": return "Unreachable"
      case "PENDING_ADOPTION": return "Pending adoption"
      case "ADOPTING": return "Adopting"
      case "GETTING_READY": return "Getting ready"
      case "UPDATING": return "Updating"
      case "ISOLATED": return "Isolated"
      case "DELETING": return "Removing"
      case "U5G_INCORRECT_TOPOLOGY": return "Incorrect topology"
      default:
        return state ? state.charAt(0) + state.slice(1).toLowerCase().replace(/_/g, " ") : "Unknown"
    }
  }

  // Secondary text. The `muted` theme token is not a text colour — a theme is
  // free to set it near the background — so dim the readable popup foreground
  // instead. 0.75 keeps caption-sized text above 4.5:1 on a dark panel.
  readonly property color detailColor:
    Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.75)

  function bucketColor(bucket) {
    switch (bucket) {
      case "offline": return Color.urgent
      case "busy": return Color.accent
      case "online": return Color.popups.text
      default: return detailColor
    }
  }

  function formatAgo(epochSeconds) {
    if (!epochSeconds) return "never"
    var deltaSeconds = Date.now() / 1000 - epochSeconds
    if (deltaSeconds < 90) return "just now"
    if (deltaSeconds < 3600) return Math.round(deltaSeconds / 60) + " min ago"
    if (deltaSeconds < 86400) return Math.round(deltaSeconds / 3600) + " h ago"
    return Math.round(deltaSeconds / 86400) + " d ago"
  }

  readonly property int pollIntervalMs: opened ? refreshIntervalMs : watchIntervalMs

  // Re-evaluated on a timer: a binding on Date.now() alone would never update.
  property real nowMs: 0

  // A failed poll leaves the previous list in place, which is right for the
  // panel. The bar badge is a claim about right now, so once the data is older
  // than three polls it says nothing rather than something wrong.
  readonly property bool dataIsStale: {
    if (lastUpdatedAt <= 0) return true
    return (nowMs - lastUpdatedAt) > Math.max(pollIntervalMs * 3, 30000)
  }

  // BarIconButton pins its width to one slot, so this must stay glyph-short.
  readonly property string barSummary: {
    if (!showBarClients || !initialized) return ""
    if (lastError !== "" || dataIsStale) return ""
    return String(summary.clients)
  }

  readonly property string tooltipSummary: {
    if (needsLogin) return "UniFi: not signed in"
    if (dataIsStale && lastUpdatedAt > 0)
      return "UniFi: last updated " + formatAgo(lastUpdatedAt / 1000)
    if (lastError !== "") return "UniFi: " + lastError
    if (!initialized) return "UniFi: loading…"
    var parts = []
    if (summary.offline > 0) parts.push(summary.offline + " offline")
    parts.push(summary.online + "/" + summary.devices + " devices online")
    parts.push(summary.clients + " clients")
    return parts.join(" · ")
  }

  // --- sign-in ----------------------------------------------------------

  // Setup asks for an API key without echo, so it runs in a terminal rather
  // than in the panel. The script pokes `refresh` over IPC when it succeeds.
  function signIn() {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(loginPath))
    close()
  }

  // Panel's own IpcHandler is replaced so that `refresh` can sit next to
  // open/close/toggle under the one target the plugin already publishes.
  manageIpc: false

  IpcHandler {
    target: root.pluginId

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // --- fetching ---------------------------------------------------------

  function refresh() {
    if (fetchProcess.running) return
    refreshing = true
    fetchProcess.command = [backendPath]
    fetchProcess.running = true
  }

  function applyOutput(text) {
    refreshing = false
    initialized = true

    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The UniFi helper returned something unreadable"
      return
    }

    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      console.warn("unifi: poll failed:", lastError)
      needsLogin = parsed.needsLogin === true
      return
    }

    lastError = ""
    needsLogin = false
    devices = (parsed && parsed.devices) ? parsed.devices : []
    if (parsed && parsed.site) site = parsed.site
    if (parsed && parsed.summary) summary = parsed.summary
    gateway = (parsed && parsed.gateway) ? parsed.gateway : null
    lastUpdatedAt = Date.now()
    recordRates()

    evaluateNotifications()
  }

  function recordRates() {
    if (!gateway || !gateway.stats) return
    var st = gateway.stats
    if (st.rxBps === null || st.txBps === null) return
    var stamp = String(st.heartbeatAt || "")
    if (stamp !== "" && stamp === lastHeartbeatAt) return
    lastHeartbeatAt = stamp
    var next = rateHistory.slice()
    next.push({ t: Date.now(), rx: st.rxBps, tx: st.txBps })
    if (next.length > rateHistoryCap) next.splice(0, next.length - rateHistoryCap)
    rateHistory = next
  }

  // --- notifications ----------------------------------------------------

  // Only a transition is worth announcing. `previous` is undefined on the
  // first poll of a session, which deliberately announces nothing — the
  // widget starting up is not an event.
  function notificationFor(device, previous) {
    if (previous === undefined) return null
    if (device.bucket === previous.bucket) return null
    if (device.bucket === "offline" && notifyOffline)
      return { urgency: "critical", body: stateLabel(device.state) }
    if (device.bucket === "online" && previous.bucket === "offline" && notifyOnline)
      return { urgency: "normal", body: "Back online" }
    return null
  }

  function evaluateNotifications() {
    var seen = {}
    var stamps = notifiedAt
    var now = Date.now()

    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device.id) continue
      seen[device.id] = { bucket: device.bucket }

      var notification = notificationFor(device, lastSeenById[device.id])
      if (!notification) continue

      var last = stamps[device.id] || 0
      if (now - last < notifyCooldownMs) continue
      stamps[device.id] = now

      notify(device.name, notification.body, notification.urgency)
    }

    lastSeenById = seen
    notifiedAt = stamps
  }

  function notify(title, body, urgency) {
    notifyProcess.running = false
    notifyProcess.command = [
      "omarchy-notification-send", "-a", "UniFi",
      "-u", urgency || "normal",
      String(title || "Device"), String(body || "")
    ]
    notifyProcess.running = true
  }

  // --- processes and timers ---------------------------------------------

  Process {
    id: fetchProcess
    running: false
    command: []

    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyOutput(fetchStdout.text)
        return
      }
      root.refreshing = false
      root.initialized = true
      var detail = String(fetchStderr.text || "").replace(/\s+/g, " ").trim()
      root.lastError = detail !== ""
        ? detail
        : "The UniFi helper exited with code " + exitCode
    }
  }

  Process {
    id: notifyProcess
    running: false
    command: []
  }

  Timer {
    interval: root.pollIntervalMs
    running: root.opened || root.watchEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Drives dataIsStale, independent of the poll timer so a wedged poll
    // cannot also freeze the staleness check that reveals it.
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // A newly opened panel should not show data from twenty minutes ago.
  onOpenedChanged: if (opened) refresh()

  // --- bar button -------------------------------------------------------

  Component {
    id: ubiquitiMark
    Item {
      UbiquitiIcon {
        anchors.centerIn: parent
        iconSize: Style.bar.iconCanvas
        // Same rule as the text glyph: urgent while something is offline.
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        Behavior on color { ColorAnimation { duration: 160 } }
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barSummary !== "" ? root.barSummary : root.barGlyph
    // The client count, when shown, replaces the mark: BarIconButton renders
    // either the component or the text, never both.
    iconComponent: root.barSummary !== "" ? null : ubiquitiMark
    dimmed: root.needsLogin || root.lastError !== ""
    // Not being set up yet is dimmed, not urgent: nothing is wrong with the
    // network, the plugin just has nothing to say.
    active: root.summary.offline > 0 || (root.lastError !== "" && !root.needsLogin)
    activeColor: Color.urgent
    tooltipText: root.tooltipSummary
    slotSize: Style.bar.statusSlot

    // Count of offline devices, drawn in the slot corner so the bar width
    // never changes. Same idiom as the first-party widgets.
    Rectangle {
      id: offlineBadge
      visible: root.summary.offline > 0 && root.lastError === "" && !root.dataIsStale
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.horizontalCenterOffset: button.opticalSize / 2 - Style.space(1)
      anchors.verticalCenterOffset: -(button.opticalSize / 2 - Style.space(2))
      height: badgeLabel.implicitHeight + Style.spaceReal(1)
      width: Math.max(height, badgeLabel.implicitWidth + Style.spaceReal(3))
      radius: height / 2
      color: Color.urgent
      border.width: 1
      border.color: Color.bar.background

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: String(root.summary.offline)
        color: Color.bar.background
        font.family: Style.font.family
        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.78))
        font.bold: true
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // --- popup ------------------------------------------------------------

  KeyboardPanel {
    id: networkPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: networkPanel.fittedContentWidth(Style.space(400))
    contentHeight: networkPanel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // One action per press: a held key would otherwise refetch every repeat.
      property string heldKey: ""
      Keys.onReleased: function(event) { if (!event.isAutoRepeat) keyCatcher.heldKey = "" }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (heldKey === key) return
        heldKey = key
        if (key === "r") root.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          width: parent.width
          text: root.site.name !== "" ? "UniFi · " + root.site.name : "UniFi"
        }

        // Sign-in prompt takes over the panel: nothing else can work without it.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsLogin

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError !== "" ? root.lastError : "No UniFi controller configured."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Enter your controller's address and an API key from "
              + "Settings → Control Plane → Integrations. The key is stored in the keyring."
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Set up"
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.signIn()
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Or run unifi-login in a terminal."
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: !root.needsLogin && root.lastError !== ""
          text: root.lastError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: !root.initialized && root.lastError === ""
          text: "Loading…"
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // Client summary
        Text {
          width: parent.width
          visible: root.initialized && !root.needsLogin && root.lastError === ""
          text: root.summary.clients + " clients"
            + "  ·  " + root.summary.wireless + " wireless"
            + "  ·  " + root.summary.wired + " wired"
            + (root.summary.vpn > 0 ? "  ·  " + root.summary.vpn + " VPN" : "")
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.initialized && !root.needsLogin && root.lastError === "" && root.devices.length === 0
          text: "No devices on this site."
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.devices

          DeviceRow {
            id: deviceEntry

            required property var modelData

            width: column.width
            device: deviceEntry.modelData
            host: root
            gatewayStats: root.showGatewayStats && root.gateway && root.gateway.stats
              && String(deviceEntry.modelData.id) === String(root.gateway.id)
              ? root.gateway.stats : null
            rateHistory: root.rateHistory
          }
        }

        Text {
          width: parent.width
          text: root.refreshing
            ? "Refreshing…"
            : (root.lastUpdatedAt > 0
               ? "Updated " + root.formatAgo(root.lastUpdatedAt / 1000) + "   ·   R to refresh"
               : "")
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
