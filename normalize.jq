# Reshape {site, devices, clients} from the UniFi Network Integration API into
# the flat model the widget renders. Every field is optional here so a sparse
# object normalizes without error rather than throwing.
#
#   jq -f normalize.jq < raw.json

def as_number($v): if ($v | type) == "number" then $v else null end;

# The API's device.state values (the enum in the controller's OpenAPI document:
# ONLINE, OFFLINE, PENDING_ADOPTION, UPDATING, GETTING_READY, ADOPTING,
# DELETING, CONNECTION_INTERRUPTED, ISOLATED, U5G_INCORRECT_TOPOLOGY), folded
# to what the panel distinguishes.
# CONNECTION_INTERRUPTED is a device the controller can no longer hear from,
# so it is treated as offline for the badge and notifications.
def bucket:
  . as $s
  | if $s == "ONLINE" then "online"
    elif $s == "OFFLINE" or $s == "CONNECTION_INTERRUPTED" then "offline"
    elif $s == "UPDATING" or $s == "GETTING_READY" or $s == "ADOPTING" or $s == "PENDING_ADOPTION" then "busy"
    else "other" end;

# Which role a device plays. The API's features enum is switching, accessPoint
# and gateway, but a UCG Fiber on Network 10.5 reports only "switching", so
# the model name is the fallback tell for Ubiquiti's gateway lines (Dream
# Machine, Cloud Gateway, Security Gateway, Express, …).
def is_gateway:
  ((.features // []) | index("gateway")) != null
  or ((.model // "") | test("^(UDM|UCG|UXG|USG|UDR|UDW|UX|EFG)([- ]|$)|Dream|Gateway|Fortress|Express"; "i"));

def kind:
  if is_gateway then "gateway"
  elif ((.features // []) | index("accessPoint")) != null then "ap"
  elif ((.features // []) | index("switching")) != null then "switch"
  else "other" end;

# The gateway leads the list because it is what everything else hangs off,
# then everything reachable, with offline devices last where they do not push
# the working network out of view. Within a group: access points, switches,
# then by name.
def sort_key:
  [ (if .kind == "gateway" then 0 else 1 end),
    (if .bucket == "online" then 0 elif .bucket == "busy" then 1 else 2 end),
    (if .kind == "ap" then 0 elif .kind == "switch" then 1 else 2 end),
    .name ];

def display_name: (.name // .model // .macAddress // "Device") | tostring;

# The gateway's latest statistics, when the caller fetched them: rates on its
# uplink (the WAN), load and uptime. Bits per second are kept as the API gives
# them; the panel chooses the unit.
def gateway_stats:
  if (.stats // null) == null then null else
    {
      uptimeSec: as_number(.stats.uptimeSec),
      heartbeatAt: (.stats.lastHeartbeatAt // null),
      cpuPct: as_number(.stats.cpuUtilizationPct),
      memPct: as_number(.stats.memoryUtilizationPct),
      load1: as_number(.stats.loadAverage1Min),
      load5: as_number(.stats.loadAverage5Min),
      load15: as_number(.stats.loadAverage15Min),
      rxBps: as_number(.stats.uplink?.rxRateBps),
      txBps: as_number(.stats.uplink?.txRateBps)
    }
  end;

# Five-minute WAN buckets from the classic report API, turned into average
# bits per second per bucket. Rows are per gateway (keyed by MAC in `gw`); the
# caller's gateway is matched when the MAC is known, otherwise all rows count.
def report_history($mac):
  if (.report // null) == null then null else
    (.report
     | map(select((.time | type) == "number"))
     | (if $mac != "" and (map(select(.gw == $mac)) | length) > 0
        then map(select(.gw == $mac)) else . end)
     | sort_by(.time)
     | map({
         t: .time,
         rxBps: ((as_number(.["wan-rx_bytes"]) // 0) * 8 / 300),
         txBps: ((as_number(.["wan-tx_bytes"]) // 0) * 8 / 300)
       }))
  end;

# WAN state from the classic stat/health "wan" subsystem, with link names from
# the documented /wans list. uptime_stats is keyed WAN, WAN2, … in the same
# order the controller lists the links, so the names are matched by position
# when the counts agree and the key is used as the name otherwise.
def wan_state:
  if (.health // null) == null then null else
    ((.health // []) | map(select(.subsystem == "wan")) | .[0] // null) as $wan
    | ((.health // []) | map(select(.subsystem == "www")) | .[0] // null) as $www
    | if $wan == null then null else
      ((.wans // []) | map(.name // "")) as $names
      | (($wan.uptime_stats // {}) | to_entries | sort_by(.key)) as $links
      # The gateway's own uptime, to tell an unused port from a failed link:
      # a link whose downtime is as old as the gateway has never been up.
      | (($wan["gw_system-stats"].uptime // null) | if type == "string" then (tonumber? // null) else . end) as $gw_uptime
      | {
          status: ($wan.status // "unknown"),
          ip: ($wan.wan_ip // null),
          gateway: (($wan.gateways // [])[0] // null),
          isp: ($wan.isp_name // $wan.isp_organization // null),
          asn: as_number($wan.asn),
          latencyMs: as_number($www.latency),
          uptimeSec: as_number($www.uptime),
          links: ($links | to_entries | map(
            .key as $i | .value.key as $key | .value.value as $u
            | (($u.uptime // 0) > 0 and (($u.downtime // 0) == 0 or ($u.availability // 0) > 0)) as $up
            # Never up: no uptime, and either no downtime figure at all or one
            # that reaches back to (within ten minutes of) the gateway's boot.
            # A second WAN port with nothing plugged in looks exactly like
            # this, and it is not a fault.
            | ((($u.uptime // 0) == 0)
               and (($u.availability // 0) == 0)
               and (($u.downtime // null) == null
                    or ($gw_uptime != null and ($u.downtime // 0) >= $gw_uptime - 600))) as $never_up
            | {
                key: $key,
                name: (if ($names | length) == ($links | length) then ($names[$i] // $key) else $key end),
                up: $up,
                state: (if $up then "up" elif $never_up then "unused" else "down" end),
                availabilityPct: as_number($u.availability),
                latencyMs: as_number($u.latency_average),
                uptimeSec: as_number($u.uptime),
                downtimeSec: as_number($u.downtime),
                periodSec: as_number($u.time_period)
              }))
        }
      end
  end;

# Client counts, taken from the classic health rows the fetch already has —
# the client list itself is never requested. wlan and lan each count users,
# guests and IoT; their sum is shown as the total so the line always adds up
# (the controller's own num_sta can differ by its own accounting). The rows
# carry no VPN figure. Null when the health report is missing or countless.
def health_clients:
  if (.health // null) == null then null else
    ((.health // []) | map(select(.subsystem == "wlan")) | .[0] // null) as $wlan
    | ((.health // []) | map(select(.subsystem == "lan")) | .[0] // null) as $lan
    | (if $wlan == null then null
       else (as_number($wlan.num_user) // 0) + (as_number($wlan.num_guest) // 0)
            + (as_number($wlan.num_iot) // 0) end) as $wireless
    | (if $lan == null then null
       else (as_number($lan.num_user) // 0) + (as_number($lan.num_guest) // 0)
            + (as_number($lan.num_iot) // 0) end) as $wired
    | if $wireless == null and $wired == null then null
      else {clients: (($wireless // 0) + ($wired // 0)), wireless: $wireless, wired: $wired} end
  end;

(.site // {}) as $site
| gateway_stats as $stats
| wan_state as $wan
| ((.devices // []) | map(
    (.state // "OFFLINE" | tostring) as $state
    | {
        id: (.id // .macAddress // ""),
        name: display_name,
        model: (.model // ""),
        mac: (.macAddress // ""),
        ip: (.ipAddress // ""),
        state: $state,
        bucket: ($state | bucket),
        online: (($state | bucket) == "online"),
        features: (.features // []),
        kind: kind,
        firmwareUpdatable: (.firmwareUpdatable // false)
      }
  ) | sort_by(sort_key)) as $devices
| ($devices | map(select(.kind == "gateway")) | .[0] // null) as $gateway
| (health_clients // {clients: null, wireless: null, wired: null}) as $hc
| {
    # ref is the classic-API reference as vetted by the fetch; the widget
    # hands it back on the next poll so the site lookup runs only once.
    site: {id: ($site.id // ""), name: ($site.name // $site.internalReference // ""),
           ref: (.siteRef // "")},
    devices: $devices,
    # The first gateway is the one whose statistics are fetched and graphed.
    gateway: (if $gateway == null then null
              else {id: $gateway.id, name: $gateway.name, stats: $stats,
                    history: report_history($gateway.mac), wan: $wan} end),
    summary: {
      devices: ($devices | length),
      online: ($devices | map(select(.bucket == "online")) | length),
      offline: ($devices | map(select(.bucket == "offline")) | length),
      busy: ($devices | map(select(.bucket == "busy")) | length),
      updatable: ($devices | map(select(.firmwareUpdatable)) | length),
      clients: $hc.clients,
      wired: $hc.wired,
      wireless: $hc.wireless
    }
  }
