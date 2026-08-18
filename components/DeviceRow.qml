pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One UniFi device in the list: role glyph, name and state, model and address,
// and how many clients hang off it. The gateway additionally carries its
// statistics block underneath.
//
// `host` is the widget root, which owns the formatting helpers and the theme
// colours; the row itself keeps no state beyond what it is given.
Column {
  id: row

  required property var device
  required property var host

  // Set only on the gateway row; null everywhere else.
  property var gatewayStats: null
  property var rateHistory: []
  property var rateReport: null
  property var wanState: null

  spacing: Style.space(6)

  Row {
    width: parent.width
    spacing: Style.space(10)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      horizontalAlignment: Text.AlignHCenter
      text: row.host.kindGlyph(row.device.kind)
      color: row.host.bucketColor(row.device.bucket)
      font.family: Style.font.family
      font.pixelSize: Style.font.body + 4
    }

    Column {
      width: parent.width - glyph.width - Style.space(10)
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: parent.width - stateText.implicitWidth - Style.space(8)
          elide: Text.ElideRight
          text: row.device.name
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          id: stateText
          text: row.host.stateLabel(row.device.state)
          color: row.host.bucketColor(row.device.bucket)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: parent.width - clientText.implicitWidth - Style.space(8)
          elide: Text.ElideRight
          text: [row.device.model, row.device.ip].filter(function(s) { return s !== "" }).join("  ·  ")
          color: row.host.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          id: clientText
          text: row.device.online && row.device.kind !== "gateway"
            ? row.device.clients + (row.device.clients === 1 ? " client" : " clients")
            : (row.device.firmwareUpdatable ? "Update available" : "")
          color: row.host.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  GatewayStats {
    // Indented under the name, past the glyph column.
    x: Style.space(22) + Style.space(10)
    width: parent.width - x
    visible: row.gatewayStats !== null
    host: row.host
    latest: row.gatewayStats
    history: row.rateHistory
    report: row.rateReport
    wan: row.wanState
  }

  // The gateway block is a section of its own; a rule keeps the device list
  // below it from reading as part of the graph's caption.
  PanelSeparator {
    visible: row.gatewayStats !== null
    width: parent.width
    foreground: Color.popups.text
  }
}
