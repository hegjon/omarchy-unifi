# Working notes for agents

Omarchy bar-widget plugin. This checkout *is* the installed plugin
(`~/.config/omarchy/plugins/hegjon.unifi`), so edits are live.

## Verifying changes

- `test/lint` (qmllint), `test/test-normalize`, `test/test-fetch` (stub
  controller, checks hostile ids), `test/test-manifest`,
  `omarchy-plugin-validate .`, and the shellcheck line from
  `.github/workflows/ci.yml` (`shellcheck --severity=warning unifi-fetch
  unifi-login lib/unifi-common.sh test/test-normalize test/test-manifest
  test/test-fetch test/lint`). Run all of them before pushing.
- The shell hot-reloads the plugin on file change, but not reliably for
  everything. For a trustworthy check run `omarchy-restart-shell`, wait ~7 s,
  then read `journalctl --user --since "30 sec ago" | grep -i unifi`.
- IPC: `omarchy-shell hegjon.unifi open|close|toggle|refresh`.
- No live controller is needed to test the scripts: serve
  `test/fixtures/network.json` from a stub that answers
  `/proxy/network/integration/v1/sites`, `.../devices`, `.../clients` under
  `{"data":[…],"totalCount":n}` and requires `X-API-KEY`, point `unifi-login`
  at it with `XDG_STATE_HOME` set to a scratch dir, and store a throwaway key.
  Clear the key afterwards: `secret-tool clear application hegjon.unifi type api-key`.

## API reference

- The controller documents its own Integration API at
  `https://<console>/unifi-api/network` (here: https://192.168.95.1/unifi-api/network).
  It is a UniFi OS web app; the JSON it renders, like every
  `/proxy/network/integration/v1/…` endpoint, needs the API key
  (`X-API-KEY`), so read it in a browser signed in to the console. Prefer it
  over memory when a field name or `state` value is in doubt; `normalize.jq`
  and `test/fixtures/network.json` must agree with it. The OpenAPI document
  behind that page is `/proxy/network/api-docs/integration.json` (found via
  `/api/apps` → `integrationApis[].apiDocsLocation`). It is served to a
  UniFi OS browser session, not to the API key: copy the request from the
  browser's dev tools as curl (cookies `TOKEN` and `JSESSIONID`) and pipe it
  to a file. Do not commit it or the cookies.
- Checked live against Network 10.5.67 (UCG Fiber) on 2026-08-18: device
  keys are `features, firmwareUpdatable, firmwareVersion, id, interfaces,
  ipAddress, macAddress, model, name, state, supported`; client keys are
  `access, connectedAt, id, ipAddress, macAddress, name, type,
  uplinkDeviceId`; `features` seen: `accessPoint`, `switching` (the gateway
  reports only `switching`, hence the model-name test); the spec's enums are
  features `switching|accessPoint|gateway`, interfaces `ports|radios`,
  client `type` `WIRED|WIRELESS|VPN|TELEPORT` (only the first two carry
  `uplinkDeviceId`); `/info` returns
  `{"applicationVersion": …}`. A gateway's `ipAddress` is its WAN address.

## The report API

- `unifi-fetch` also POSTs to the classic
  `…/proxy/network/api/s/<internalReference>/stat/report/5minutes.gw` with
  `{attrs:[time, wan-rx_bytes, wan-tx_bytes], start, end}` (ms). It accepts
  the same API key. Rows are per gateway MAC (`gw`); bytes are per 5-min
  bucket, so rate = bytes × 8 / 300. Retention here: 5minutes ≈ 24 h, hourly
  ≈ 7 d, daily ≈ 3 months. Cached 4 min in `$XDG_RUNTIME_DIR/omarchy-unifi/`.
  Any failure leaves `gateway.history` null and the widget graphs its own
  heartbeat samples instead — never let it become fatal.

- Client counts come solely from the classic stat/health rows (wlan and lan
  `num_user + num_guest + num_iot`; no VPN figure exists there). The
  Integration `/clients` endpoint is never called — the widget shows no
  per-device client counts for the same reason.

- WAN state comes from classic `…/api/s/<site>/stat/health` (GET, same key):
  the `wan` subsystem row has `status, wan_ip, gateways[], isp_name, asn,
  uptime_stats{WAN, WAN2, …}` (availability, latency_average, uptime or
  downtime, time_period 86400) and the `www` row has `latency, uptime`. Link
  names come from the documented `/sites/{id}/wans`, matched by position
  only when the counts agree. Fetched every poll; small. Failure → `wan`
  null → no WAN lines. A link is `unused` (shown muted as "Not connected")
  when it has no uptime and its downtime reaches back to the gateway's boot
  (`gw_system-stats.uptime`, ±10 min): an empty second WAN port looks like
  that and is not a fault. A link that was up and dropped is `down`.

## Testing the graph

- The graph needs samples, one per controller heartbeat (~24 s). To see it
  quickly, point `backendPath` at a stub that prints the fixture with a
  synthetic `stats` block and a fresh `lastHeartbeatAt` each call, then
  `omarchy-shell hegjon.unifi refresh` in a loop. Swap the file back from a
  copy — **not** `git checkout`, which discards every uncommitted edit in it.

## Things to keep

- The API key never reaches argv: it goes to curl as a header line in a
  config on stdin (`unifi_http`), and `secret-tool` reads it from stdin.
- `fetch_all` sets `FETCHED` rather than printing, because `die` inside a
  `$(...)` would end only the subshell and its JSON would be captured as data.
- The plugin id (`hegjon.unifi`) is also the keyring `application` attribute
  and the IPC target. Renaming it orphans the stored key.
- unifi-login stores only the site id — deliberate: a rename or typo fix on
  the controller must keep polling the same site. unifi-fetch resolves the
  name and internalReference from /sites only when not told them: the widget
  holds the last poll's site and hands it back as `--site=<id>
  --site-ref=<ref>`, so the lookup runs once per widget lifetime. The pair
  counts only when the id matches the config, the ref only if it is a plain
  token, and the ref the widget passes is the one the fetch vetted
  (`site.ref` in the output) — never the controller's raw string. There is
  no `GET /sites/{id}`; the lookup is `/sites?filter=id.eq(<uuid>)&limit=1`
  — the UUID goes **unquoted** (quoted means STRING and the filter wants
  UUID; checked against Network 10.5.67), with one plain /sites page (the
  API's default limit, 25) as fallback for controllers without filtering.
- Style follows hegjon.prusa-connect: comments explain *why*; imperative
  commit subjects; version lives in `manifest.json`; annotated `vX.Y.Z` tags.
