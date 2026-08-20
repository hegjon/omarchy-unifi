pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "./components"

// Bar widget and popup for a UniFi Network controller.
//
// All network work happens in unifi-fetch, which prints the normalized model
// on stdout and reports failures as {"error":…} rather than dying, so the panel
// can always render a reason. Nothing here ever touches the API key.
//
// Names, models, ISP and link names are controller data, so every Text in
// this plugin is PlainText: AutoText would render markup found in them, and
// an <img> tag would make the shell fetch whatever URL it names. That goes
// for the shell's own Text-derived components too (PanelSectionHeader keeps
// the AutoText default), so any of them showing controller data sets it.
Panel {
  id: root

  readonly property string pluginId: "hegjon.unifi"

  moduleName: pluginId
  ipcTarget: pluginId

  // --- state ------------------------------------------------------------

  property var devices: []
  property var site: ({ id: "", name: "", ref: "" })
  property var gateway: null
  // A site past the fetcher's device cap: `devices` holds at most the
  // gateway and summary.devices is the controller's claim. controllerInfo
  // carries the configured controller address ({url}).
  property bool oversized: false
  property var controllerInfo: null

  // The controller's own device list, for the oversized view. UniFi OS
  // consoles serve the Network app at /network/<site>/devices; without a
  // site reference the console root still gets the user there.
  readonly property string deviceListUrl: {
    if (!controllerInfo || !controllerInfo.url) return ""
    return site && site.ref
      ? controllerInfo.url + "/network/" + site.ref + "/devices"
      : controllerInfo.url
  }

  // WAN rate samples for the graph, oldest first: {t, rx, tx}. One entry per
  // controller heartbeat, so consecutive polls that see the same heartbeat
  // add nothing — the rates would just be repeated. Capped so a shell that
  // has been up for a week does not drag a week of points into every paint.
  property var rateHistory: []
  property string lastHeartbeatAt: ""
  readonly property int rateHistoryCap: 120

  // The panel's height ceiling. The device list takes whatever of it the
  // gateway block, headers and footer leave over, so the panel never grows
  // past this and the gateway is never pushed out of view.
  readonly property real panelMaxHeight: Style.space(760)
  property var summary: ({ devices: 0, online: 0, offline: 0, busy: 0, updatable: 0, clients: null, wired: null, wireless: null })
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
  // Fast while the panel is open so the gateway's rates and load feel live:
  // the controller heartbeats every ~20 s, so most polls repeat the last
  // sample, but each is four small LAN requests (the report is cached).
  readonly property int refreshIntervalMs: intSetting("refreshIntervalSec", 5, 1, 300) * 1000
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
    // The client count is health-derived and can be missing (no gateway, or
    // the report failed); the device count stands in whenever it is.
    if (oversized || summary.clients === null || summary.clients === undefined)
      return String(summary.devices)
    return String(summary.clients)
  }

  readonly property string tooltipSummary: {
    if (needsLogin) return "UniFi: not signed in"
    if (dataIsStale && lastUpdatedAt > 0)
      return "UniFi: last updated " + formatAgo(lastUpdatedAt / 1000)
    if (lastError !== "") return "UniFi: " + lastError
    if (!initialized) return "UniFi: loading…"
    if (oversized) {
      var head = summary.devices + " devices"
      if (summary.clients !== null && summary.clients !== undefined)
        head += " · " + summary.clients + " clients"
      return head + " — full list in the UniFi web UI"
    }
    var parts = []
    if (summary.offline > 0) parts.push(summary.offline + " offline")
    parts.push(summary.online + "/" + summary.devices + " devices online")
    if (summary.clients !== null && summary.clients !== undefined)
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
    // Hand the site from the last poll back so the fetch skips its /sites
    // lookup. The ref is the token the fetch itself vetted — a raw
    // controller string never reaches argv — and the fetch re-checks both
    // against its config before trusting them.
    var cmd = [backendPath]
    if (site && site.id) {
      cmd.push("--site=" + site.id, "--site-ref=" + (site.ref || ""))
      // On an oversized site this lets the fetch get the gateway by id
      // instead of hunting the device pages again.
      if (gateway && gateway.id) cmd.push("--gateway=" + gateway.id)
    }
    fetchProcess.command = cmd
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
    if (parsed && parsed.site) {
      // A poll launched with --site-ref skipped the site lookup and reports
      // an empty name; keep the one from the poll that resolved it.
      if (parsed.site.name === "" && parsed.site.id === site.id && site.name)
        parsed.site.name = site.name
      site = parsed.site
    }
    if (parsed && parsed.summary) summary = parsed.summary
    gateway = (parsed && parsed.gateway) ? parsed.gateway : null
    oversized = (parsed && parsed.oversized === true)
    controllerInfo = (parsed && parsed.controller) ? parsed.controller : null
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

  // The title is a device name the controller chose. omarchy-notification-send
  // option-parses every argument, including the ones after the headline, and
  // hands unknown ones to notify-send — so a name that begins with a dash
  // could smuggle in a hint such as omarchy-exec, which the shell runs on
  // click. A leading dash is therefore swapped out before it becomes argv.
  function notificationArg(text, fallback) {
    var s = String(text || fallback)
    return s.charAt(0) === "-" ? "\u2011" + s.slice(1) : s   // U+2011 looks the same, is not an option
  }

  function notify(title, body, urgency) {
    notifyProcess.running = false
    notifyProcess.command = [
      "omarchy-notification-send",
      "--app-name", "UniFi",
      "-u", urgency || "normal",
      notificationArg(title, "Device"), notificationArg(body, "")
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

  // The gateway (with its statistics block) stays put at the top; every
  // other device scrolls in a list below it, so a large fleet cannot push
  // the panel off the screen or the gateway out of view.
  readonly property var gatewayDevices: devices.filter(function(d) { return d.kind === "gateway" })
  readonly property var otherDevices: devices.filter(function(d) { return d.kind !== "gateway" })

  // A newly opened panel should not show data from twenty minutes ago.
  onOpenedChanged: if (opened) refresh()

  // --- bar button -------------------------------------------------------

  Component {
    id: ubiquitiMark
    Item {
      UbiquitiIcon {
        anchors.centerIn: parent
        // The mark fills its 24-unit box edge to edge, while a font glyph
        // at the bar's icon size leaves margins inside its em box: measured
        // against the neighbouring icons, their ink is about 11 px to the
        // canvas's 16. Scale to the icon font size, then a little under.
        iconSize: Math.round(Style.bar.iconFont * 0.85)
        // The offline badge sits over the top-right corner, which is where
        // the mark's pixel dots are — the one part that says "Ubiquiti"
        // rather than "a U". Mirror the mark while the badge shows so the
        // dots swap to the uncovered side.
        transform: Scale {
          origin.x: Math.round(Style.bar.iconFont * 0.85) / 2
          xScale: offlineBadge.visible ? -1 : 1
        }
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

        textFormat: Text.PlainText
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
    contentHeight: networkPanel.fittedContentHeight(column.implicitHeight, root.panelMaxHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // j/k and the arrow keys scroll the device list, one row at a time.
      onMoveRequested: function(dx, dy) {
        if (dy === 0 || !deviceList.interactive) return
        var step = deviceList.rowHeight * dy
        deviceList.contentY = Math.max(0, Math.min(deviceList.contentHeight - deviceList.height,
                                                    deviceList.contentY + step))
      }

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

        // Height of everything in this column except the device list, so the
        // list can be sized to the space that remains. Reading each child's
        // height here binds to it, so this follows the gateway block as it
        // grows and shrinks. The list is skipped, which is what keeps this
        // from being a binding loop.
        readonly property real fixedHeight: {
          var total = 0
          for (var i = 0; i < children.length; i++) {
            var child = children[i]
            if (child === deviceList || !child.visible) continue
            total += child.height + spacing
          }
          return total
        }

        PanelSectionHeader {
          textFormat: Text.PlainText   // the site name is controller data
          width: parent.width
          text: root.site.name !== "" ? "UniFi · " + root.site.name : "UniFi"
        }

        // Sign-in prompt takes over the panel: nothing else can work without it.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsLogin

          Text {

            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError !== "" ? root.lastError : "No UniFi controller configured."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {

            textFormat: Text.PlainText
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

            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Or run unifi-login in a terminal."
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          visible: !root.needsLogin && root.lastError !== ""
          text: root.lastError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          visible: !root.initialized && root.lastError === ""
          text: "Loading…"
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // Client summary. The counts come from the controller's health
        // report — the client list is never fetched — and when the report
        // is missing they are null and the line disappears rather than
        // showing them.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.initialized && !root.needsLogin && root.lastError === ""
            && root.summary.clients !== null && root.summary.clients !== undefined
          text: {
            var parts = [root.summary.clients + " clients"]
            if (root.summary.wireless !== null && root.summary.wireless !== undefined)
              parts.push(root.summary.wireless + " wireless")
            if (root.summary.wired !== null && root.summary.wired !== undefined)
              parts.push(root.summary.wired + " wired")
            return parts.join("  ·  ")
          }
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          visible: root.initialized && !root.needsLogin && root.lastError === ""
            && root.devices.length === 0 && !root.oversized
          text: "No devices on this site."
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.gatewayDevices

          DeviceRow {
            id: gatewayEntry

            required property var modelData

            width: column.width
            device: gatewayEntry.modelData
            host: root
            gatewayStats: root.showGatewayStats && root.gateway && root.gateway.stats
              && String(gatewayEntry.modelData.id) === String(root.gateway.id)
              ? root.gateway.stats : null
            rateHistory: root.rateHistory
            rateReport: root.gateway ? (root.gateway.history || null) : null
            wanState: root.gateway ? (root.gateway.wan || null) : null
          }
        }

        // Where the device list would scroll, a site past the cap gets the
        // count and a door to the controller's own list instead.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.initialized && !root.needsLogin && root.lastError === "" && root.oversized

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.summary.devices + " devices — more than this widget lists."
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Button {
            text: "Open the device list"
            bordered: true
            fontSize: Style.font.caption
            visible: root.deviceListUrl !== ""
            onClicked: Qt.openUrlExternally(root.deviceListUrl)
          }
        }

        // ListView rather than Repeater so a long fleet scrolls inside a
        // fixed box instead of growing the panel. Same idiom as the network
        // panel's station list.
        ListView {
          id: deviceList
          width: parent.width
          // Whatever the panel ceiling leaves after the fixed content, but
          // never less than about two rows so the list stays usable.
          height: Math.min(contentHeight, Math.max(Style.space(96),
            Math.min(root.panelMaxHeight, networkPanel.availableCardHeight)
              - networkPanel.verticalContentInset - column.fixedHeight))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          visible: count > 0

          // One row plus spacing, for keyboard stepping.
          readonly property real rowHeight: (contentItem.children.length > 0
            ? contentItem.children[0].height : Style.space(40)) + spacing

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.otherDevices

          delegate: DeviceRow {
            id: deviceEntry

            required property var modelData

            width: ListView.view.width - Style.space(6)   // room for the scrollbar
            device: deviceEntry.modelData
            host: root
          }
        }

        Text {

          textFormat: Text.PlainText
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
