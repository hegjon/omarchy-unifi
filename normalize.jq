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

(.site // {}) as $site
| gateway_stats as $stats
| (.clients // []) as $clients
| ($clients | map(select(.uplinkDeviceId != null)) | group_by(.uplinkDeviceId)
   | map({key: .[0].uplinkDeviceId, value: length}) | from_entries) as $clients_by_device
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
        clients: ($clients_by_device[.id // ""] // 0),
        firmwareUpdatable: (.firmwareUpdatable // false)
      }
  ) | sort_by(sort_key)) as $devices
| ($devices | map(select(.kind == "gateway")) | .[0] // null) as $gateway
| {
    site: {id: ($site.id // ""), name: ($site.name // $site.internalReference // "")},
    devices: $devices,
    # The first gateway is the one whose statistics are fetched and graphed.
    gateway: (if $gateway == null then null
              else {id: $gateway.id, name: $gateway.name, stats: $stats} end),
    summary: {
      devices: ($devices | length),
      online: ($devices | map(select(.bucket == "online")) | length),
      offline: ($devices | map(select(.bucket == "offline")) | length),
      busy: ($devices | map(select(.bucket == "busy")) | length),
      updatable: ($devices | map(select(.firmwareUpdatable)) | length),
      clients: ($clients | length),
      wired: ($clients | map(select(.type == "WIRED")) | length),
      wireless: ($clients | map(select(.type == "WIRELESS")) | length),
      # Teleport is Ubiquiti's own VPN, so it counts with VPN rather than as
      # a fourth kind nobody would look for.
      vpn: ($clients | map(select(.type == "VPN" or .type == "TELEPORT")) | length)
    }
  }
