# Reshape {site, devices, clients} from the UniFi Network Integration API into
# the flat model the widget renders. Every field is optional here so a sparse
# object normalizes without error rather than throwing.
#
#   jq -f normalize.jq < raw.json

def as_number($v): if ($v | type) == "number" then $v else null end;

# The API's device.state values, folded to what the panel distinguishes.
# CONNECTION_INTERRUPTED is a device the controller can no longer hear from,
# so it is treated as offline for the badge and notifications.
def bucket:
  . as $s
  | if $s == "ONLINE" then "online"
    elif $s == "OFFLINE" or $s == "CONNECTION_INTERRUPTED" then "offline"
    elif $s == "UPDATING" or $s == "GETTING_READY" or $s == "ADOPTING" or $s == "PENDING_ADOPTION" then "busy"
    else "other" end;

# Which role a device plays. A gateway also switches, so the feature list alone
# cannot single it out; the model name is the reliable tell for Ubiquiti's
# gateway lines (Dream Machine, Cloud Gateway, Security Gateway, Express, …).
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

(.site // {}) as $site
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
| {
    site: {id: ($site.id // ""), name: ($site.name // $site.internalReference // "")},
    devices: $devices,
    summary: {
      devices: ($devices | length),
      online: ($devices | map(select(.bucket == "online")) | length),
      offline: ($devices | map(select(.bucket == "offline")) | length),
      busy: ($devices | map(select(.bucket == "busy")) | length),
      updatable: ($devices | map(select(.firmwareUpdatable)) | length),
      clients: ($clients | length),
      wired: ($clients | map(select(.type == "WIRED")) | length),
      wireless: ($clients | map(select(.type == "WIRELESS")) | length)
    }
  }
