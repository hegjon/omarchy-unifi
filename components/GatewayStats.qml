pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// The gateway's vital signs under its row: WAN download and upload right now,
// a graph of both over the samples the widget has collected, and CPU, memory
// and uptime.
//
// `history` is an array of {t, rx, tx} in bits per second, oldest first. The
// widget owns it and appends one entry per controller heartbeat, so the graph
// spans however long the shell has been running, up to the widget's cap.
Column {
  id: stats

  required property var host
  property var latest: null
  property var history: []

  spacing: Style.space(4)

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

  // Rates line: what is flowing through the WAN right now.
  Row {
    width: parent.width
    spacing: Style.space(14)

    Text {
      text: stats.downGlyph + " " + stats.formatRate(stats.latest ? stats.latest.rxBps : null)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      text: stats.upGlyph + " " + stats.formatRate(stats.latest ? stats.latest.txBps : null)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // The graph. Download is the filled area, upload the dashed line: two
  // series told apart by shape rather than hue, since a theme is free to
  // make accent and text the same colour, and this one does.
  Canvas {
    id: graph
    width: parent.width
    height: Style.space(56)
    visible: stats.history.length >= 2

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

      var points = stats.history
      var count = points.length
      if (count < 2) return

      var peak = 1000   // never scale below 1 kbit/s, or idle noise fills the box
      for (var i = 0; i < count; i++) {
        var p = points[i]
        if (p.rx > peak) peak = p.rx
        if (p.tx > peak) peak = p.tx
      }
      // A little headroom so the peak does not kiss the top edge.
      peak *= 1.08

      var top = 1, bottom = height - 1
      function xAt(index) { return index * (width - 1) / (count - 1) }
      function yAt(value) { return bottom - (bottom - top) * Math.max(0, value) / peak }

      // Baseline.
      ctx.strokeStyle = axisColor
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, bottom + 0.5)
      ctx.lineTo(width, bottom + 0.5)
      ctx.stroke()

      // Download: filled area under a solid line.
      ctx.beginPath()
      ctx.moveTo(xAt(0), bottom)
      for (var d = 0; d < count; d++) ctx.lineTo(xAt(d), yAt(points[d].rx))
      ctx.lineTo(xAt(count - 1), bottom)
      ctx.closePath()
      ctx.fillStyle = fillColor
      ctx.fill()

      ctx.beginPath()
      for (var l = 0; l < count; l++) {
        if (l === 0) ctx.moveTo(xAt(l), yAt(points[l].rx))
        else ctx.lineTo(xAt(l), yAt(points[l].rx))
      }
      ctx.strokeStyle = lineColor
      ctx.lineWidth = 1.5
      ctx.setLineDash([])
      ctx.stroke()

      // Upload: dashed line, no fill.
      ctx.beginPath()
      for (var u = 0; u < count; u++) {
        if (u === 0) ctx.moveTo(xAt(u), yAt(points[u].tx))
        else ctx.lineTo(xAt(u), yAt(points[u].tx))
      }
      ctx.strokeStyle = lineColor
      ctx.lineWidth = 1.2
      ctx.setLineDash([3, 3])
      ctx.stroke()
      ctx.setLineDash([])
    }
  }

  // Scale and span of the graph, so the picture has units.
  Text {
    width: parent.width
    visible: graph.visible
    text: {
      var pts = stats.history
      var peak = 0
      for (var i = 0; i < pts.length; i++) peak = Math.max(peak, pts[i].rx, pts[i].tx)
      var spanSec = pts.length >= 2 ? (pts[pts.length - 1].t - pts[0].t) / 1000 : 0
      var span = spanSec >= 3600 ? Math.round(spanSec / 3600 * 10) / 10 + " h"
                                 : Math.max(1, Math.round(spanSec / 60)) + " min"
      return "peak " + stats.formatRate(peak) + "  ·  last " + span
        + "  ·  " + stats.downGlyph + " filled, " + stats.upGlyph + " dashed"
    }
    color: stats.host.detailColor
    font.family: Style.font.family
    font.pixelSize: Math.max(8, Math.round(Style.font.caption * 0.9))
  }

  Text {
    width: parent.width
    visible: graph.visible === false && stats.history.length > 0
    text: "Collecting samples for the graph…"
    color: stats.host.detailColor
    font.family: Style.font.family
    font.pixelSize: Math.max(8, Math.round(Style.font.caption * 0.9))
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
