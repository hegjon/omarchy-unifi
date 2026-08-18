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

## Things to keep

- The API key never reaches argv: it goes to curl as a header line in a
  config on stdin (`unifi_http`), and `secret-tool` reads it from stdin.
- `fetch_all` sets `FETCHED` rather than printing, because `die` inside a
  `$(...)` would end only the subshell and its JSON would be captured as data.
- The plugin id (`hegjon.unifi`) is also the keyring `application` attribute
  and the IPC target. Renaming it orphans the stored key.
- Style follows hegjon.prusa-connect: comments explain *why*; imperative
  commit subjects; version lives in `manifest.json`; annotated `vX.Y.Z` tags.
