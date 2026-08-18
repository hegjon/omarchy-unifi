pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// The gateway's vital signs under its row: WAN download and upload right now,
// each with a graph over the samples the widget has collected, and CPU,
// memory and uptime.
//
// `history` is an array of {t, rx, tx} in bits per second, oldest first. The
// widget owns it and appends one entry per controller heartbeat, so the graph
// spans however long the shell has been running, up to the widget's cap.
Column {
  id: stats

  required property var host
  property var latest: null
  // The widget's own heartbeat samples, {t, rx, tx}, oldest first.
  property var history: []
  // Twelve hours of five-minute WAN buckets from the controller, {t, rxBps,
  // txBps}, or null when that report could not be fetched.
  property var report: null
  // WAN state from the controller's health report, or null when unavailable.
  property var wan: null

  // What the graphs plot: the controller's report when it has one, since it
  // is there in full the moment the panel opens and survives a shell restart;
  // otherwise whatever the widget has collected itself since it started.
  readonly property bool usingReport: report !== null && report !== undefined && report.length >= 2
  readonly property var points: usingReport
    ? report
    : history.map(function(p) { return { t: p.t, rxBps: p.rx, txBps: p.tx } })

  spacing: Style.space(6)

  // Bits per second, as the API reports them, in the unit that fits.
  function formatRate(bps) {
    if (bps === null || bps === undefined || !isFinite(bps)) return "--"
    if (bps >= 1e9) return (bps / 1e9).toFixed(2) + " Gbit/s"
    if (bps >= 1e6) return (bps / 1e6).toFixed(1) + " Mbit/s"
    if (bps >= 1e3) return Math.round(bps / 1e3) + " kbit/s"
    return Math.round(bps) + " bit/s"
  }

  function formatUptime(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds)) return "--"
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor((seconds % 86400) / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    return minutes + "m"
  }

  function formatPct(value) {
    if (value === null || value === undefined || !isFinite(value)) return "--"
    return Math.round(value) + "%"
  }

  // Download keeps the accent; upload takes the accent's complementary hue so
  // the two graphs are told apart at a glance. A theme whose accent is grey
  // has no hue to rotate, so upload keeps the default accent there — the two
  // graphs are still separate boxes with their own headers, and borrowing
  // the urgent colour would read as an alarm.
  readonly property color downColor: Color.accent
  readonly property color upColor: {
    var a = Color.accent
    if (a.hslSaturation < 0.2) return a
    return Qt.hsla((a.hslHue + 0.5) % 1, a.hslSaturation, a.hslLightness, 1)
  }

  readonly property string downGlyph: String.fromCodePoint(0xF0045)   // md-arrow_down
  readonly property string upGlyph: String.fromCodePoint(0xF005D)     // md-arrow_up

  function peakOf(seriesKey) {
    var peak = 0
    for (var i = 0; i < points.length; i++) peak = Math.max(peak, points[i][seriesKey])
    return peak
  }

  readonly property string spanLabel: {
    var pts = points
    if (pts.length < 2) return ""
    var spanSec = (pts[pts.length - 1].t - pts[0].t) / 1000
    // The report's buckets are stamped at their start, so twelve hours of
    // them span 11 h 55 min; round to the hour rather than say 11.9.
    if (usingReport) return Math.max(1, Math.round((spanSec + 300) / 3600)) + " h, 5-min avg"
    if (spanSec >= 3600) return Math.round(spanSec / 3600 * 10) / 10 + " h"
    return Math.max(1, Math.round(spanSec / 60)) + " min"
  }

  // One graph per direction, each on its own scale: upload is usually a
  // fraction of download, and on a shared axis it flattened into the
  // baseline. Same shape for both, so the eye compares them by height only.
  RateGraph { key: "rx"; glyph: stats.downGlyph; label: "Download"; tint: stats.downColor }
  RateGraph { key: "tx"; glyph: stats.upGlyph; label: "Upload"; tint: stats.upColor }

  component RateGraph: Column {
    id: rate

    required property string key
    required property string glyph
    required property string label
    required property color tint

    width: parent.width
    spacing: Style.space(2)

    readonly property string seriesKey: key === "rx" ? "rxBps" : "txBps"
    readonly property real current: stats.latest ? stats.latest[seriesKey] : NaN
    readonly property real peak: stats.peakOf(seriesKey)

    Row {
      width: parent.width

      Text {
        id: nowText
        text: rate.glyph + " " + stats.formatRate(rate.current)
        color: rate.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width - nowText.implicitWidth
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        text: stats.points.length >= 2
          ? "peak " + stats.formatRate(rate.peak) + "  ·  last " + stats.spanLabel
          : "collecting samples…"
        color: stats.host.detailColor
        font.family: Style.font.family
        font.pixelSize: Math.max(8, Math.round(Style.font.caption * 0.9))
      }
    }

    Canvas {
      id: graph
      width: parent.width
      height: Style.space(40)

      readonly property color lineColor: rate.tint
      readonly property color fillColor: Qt.rgba(rate.tint.r, rate.tint.g, rate.tint.b, 0.22)
      readonly property color axisColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.15)

      onWidthChanged: requestPaint()
      onLineColorChanged: requestPaint()
      Connections {
        target: stats
        function onPointsChanged() { graph.requestPaint() }
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)

        var top = 1, bottom = height - 1

        // Baseline, drawn even before there is anything to plot so the box
        // has a floor rather than being blank space.
        ctx.strokeStyle = axisColor
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, bottom + 0.5)
        ctx.lineTo(width, bottom + 0.5)
        ctx.stroke()

        var points = stats.points
        var count = points.length
        if (count < 2) return

        // Never scale below 1 kbit/s, or idle noise fills the box; a little
        // headroom so the peak does not kiss the top edge. X is time, not
        // index, so a gap in the report (gateway offline) shows as a gap.
        var peak = Math.max(1000, rate.peak) * 1.08
        var t0 = points[0].t, t1 = points[count - 1].t
        var span = Math.max(1, t1 - t0)
        function xAt(t) { return (t - t0) * (width - 1) / span }
        function yAt(value) { return bottom - (bottom - top) * Math.max(0, value) / peak }
        var key = rate.seriesKey

        ctx.beginPath()
        ctx.moveTo(xAt(t0), bottom)
        for (var d = 0; d < count; d++) ctx.lineTo(xAt(points[d].t), yAt(points[d][key]))
        ctx.lineTo(xAt(t1), bottom)
        ctx.closePath()
        ctx.fillStyle = fillColor
        ctx.fill()

        ctx.beginPath()
        for (var l = 0; l < count; l++) {
          if (l === 0) ctx.moveTo(xAt(points[l].t), yAt(points[l][key]))
          else ctx.lineTo(xAt(points[l].t), yAt(points[l][key]))
        }
        ctx.strokeStyle = lineColor
        ctx.lineWidth = 1.5
        ctx.stroke()
      }
    }
  }

  // Health line.
  Text {
    width: parent.width
    elide: Text.ElideRight
    text: "CPU " + stats.formatPct(stats.latest ? stats.latest.cpuPct : null)
      + "  ·  Memory " + stats.formatPct(stats.latest ? stats.latest.memPct : null)
      + "  ·  Load " + (stats.latest && stats.latest.load1 !== null ? stats.latest.load1.toFixed(2) : "--")
      + "  ·  Up " + stats.formatUptime(stats.latest ? stats.latest.uptimeSec : null)
    color: stats.host.detailColor
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // WAN: who the gateway is talking to and how each link is doing. The
  // primary link's address and ISP head the section; every link then gets a
  // row of its own, since a second WAN that is down is worth seeing.
  Text {
    width: parent.width
    visible: stats.wan !== null && stats.wan !== undefined
    elide: Text.ElideRight
    text: {
      var w = stats.wan
      if (!w) return ""
      var parts = ["WAN"]
      if (w.ip) parts.push(w.ip + (w.gateway ? " via " + w.gateway : ""))
      return parts.join("  ·  ")
    }
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // ISP names run long ("Drustvo za telekomunikacije MTEL DOO"), so this
  // wraps rather than being cut off after the address.
  Text {
    width: parent.width
    visible: !!(stats.wan && stats.wan.isp)
    wrapMode: Text.WordWrap
    text: stats.wan && stats.wan.isp
      ? stats.wan.isp + (stats.wan.asn ? "  ·  AS" + stats.wan.asn : "")
      : ""
    color: stats.host.detailColor
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: stats.wan && stats.wan.links ? stats.wan.links : []

    Row {
      id: linkRow
      required property var modelData
      width: parent.width
      spacing: Style.space(8)

      readonly property bool up: linkRow.modelData.up === true
      // A port that has never been up since the gateway booted is unused,
      // not broken, so it reads as a fact rather than an alarm.
      readonly property bool unused: linkRow.modelData.state === "unused"

      Text {
        id: linkDetail
        width: parent.width - linkState.implicitWidth - Style.space(8)
        elide: Text.ElideRight
        text: {
          var l = linkRow.modelData
          var parts = [l.name || l.key]
          if (linkRow.up) {
            if (l.latencyMs !== null && l.latencyMs !== undefined) parts.push(Math.round(l.latencyMs) + " ms")
            if (l.uptimeSec) parts.push("up " + stats.formatUptime(l.uptimeSec))
            if (l.availabilityPct !== null && l.availabilityPct !== undefined)
              parts.push((Math.round(l.availabilityPct * 10) / 10) + "% last 24 h")
          } else if (linkRow.unused) {
            // Nothing to add: the state column says it all.
          } else if (l.downtimeSec) {
            parts.push("down for " + stats.formatUptime(l.downtimeSec))
          }
          return parts.join("  ·  ")
        }
        color: stats.host.detailColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        id: linkState
        text: linkRow.up ? "Online" : (linkRow.unused ? "Not connected" : "Down")
        color: linkRow.up ? Color.popups.text : (linkRow.unused ? stats.host.detailColor : Color.urgent)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
