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
  property var history: []

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

  readonly property string downGlyph: String.fromCodePoint(0xF0045)   // md-arrow_down
  readonly property string upGlyph: String.fromCodePoint(0xF005D)     // md-arrow_up

  function peakOf(key) {
    var peak = 0
    for (var i = 0; i < history.length; i++) peak = Math.max(peak, history[i][key])
    return peak
  }

  readonly property string spanLabel: {
    var pts = history
    if (pts.length < 2) return ""
    var spanSec = (pts[pts.length - 1].t - pts[0].t) / 1000
    if (spanSec >= 3600) return Math.round(spanSec / 3600 * 10) / 10 + " h"
    return Math.max(1, Math.round(spanSec / 60)) + " min"
  }

  // One graph per direction, each on its own scale: upload is usually a
  // fraction of download, and on a shared axis it flattened into the
  // baseline. Same shape for both, so the eye compares them by height only.
  RateGraph { key: "rx"; glyph: stats.downGlyph; label: "Download" }
  RateGraph { key: "tx"; glyph: stats.upGlyph; label: "Upload" }

  component RateGraph: Column {
    id: rate

    required property string key
    required property string glyph
    required property string label

    width: parent.width
    spacing: Style.space(2)

    readonly property real current: stats.latest ? stats.latest[key === "rx" ? "rxBps" : "txBps"] : NaN
    readonly property real peak: stats.peakOf(key)

    Row {
      width: parent.width

      Text {
        id: nowText
        text: rate.glyph + " " + stats.formatRate(rate.current)
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width - nowText.implicitWidth
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        text: stats.history.length >= 2
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

      readonly property color lineColor: Color.accent
      readonly property color fillColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
      readonly property color axisColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.15)

      onWidthChanged: requestPaint()
      onLineColorChanged: requestPaint()
      Connections {
        target: stats
        function onHistoryChanged() { graph.requestPaint() }
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

        var points = stats.history
        var count = points.length
        if (count < 2) return

        // Never scale below 1 kbit/s, or idle noise fills the box; a little
        // headroom so the peak does not kiss the top edge.
        var peak = Math.max(1000, rate.peak) * 1.08
        function xAt(index) { return index * (width - 1) / (count - 1) }
        function yAt(value) { return bottom - (bottom - top) * Math.max(0, value) / peak }

        ctx.beginPath()
        ctx.moveTo(xAt(0), bottom)
        for (var d = 0; d < count; d++) ctx.lineTo(xAt(d), yAt(points[d][rate.key]))
        ctx.lineTo(xAt(count - 1), bottom)
        ctx.closePath()
        ctx.fillStyle = fillColor
        ctx.fill()

        ctx.beginPath()
        for (var l = 0; l < count; l++) {
          if (l === 0) ctx.moveTo(xAt(l), yAt(points[l][rate.key]))
          else ctx.lineTo(xAt(l), yAt(points[l][rate.key]))
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
}
