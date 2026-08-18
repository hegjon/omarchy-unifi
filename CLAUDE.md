# Working notes for agents

Omarchy bar-widget plugin. This checkout *is* the installed plugin
(`~/.config/omarchy/plugins/hegjon.unifi`), so edits are live.

## Verifying changes

- `test/lint` (qmllint), `test/test-normalize`, `test/test-manifest`, and
  `omarchy-plugin-validate .`. `shellcheck` is not installed locally; CI runs it.
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
- Style follows hegjon.prusa-connect: comments explain *why*; imperative
  commit subjects; version lives in `manifest.json`; annotated `vX.Y.Z` tags.
