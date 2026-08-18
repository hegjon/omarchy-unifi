# shellcheck shell=bash
# Shared UniFi controller access, sourced by unifi-fetch and unifi-login.
#
# The controller URL and TLS choice live in a plain state file; the API key
# lives in the keyring and never reaches argv — it is handed to curl as a header
# line in a config read from stdin.
#
# Every failure is reported as JSON on stdout and exits 0, so the widget can
# render the reason rather than guess why a process died. A failure the user
# can fix by signing in carries "needsLogin": true.

readonly UNIFI_PLUGIN_ID="hegjon.unifi"

readonly UNIFI_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/unifi"
readonly UNIFI_CONFIG_FILE="$UNIFI_STATE_DIR/config"

# Set by unifi_load_config and read by the scripts that source this file.
# shellcheck disable=SC2034
UNIFI_URL=""
UNIFI_SITE=""
UNIFI_INSECURE=0
UNIFI_API_BASE=""

die() {
  jq -cn --arg m "$1" '{error: $m}'
  exit 0
}

die_needs_login() {
  jq -cn --arg m "$1" '{error: $m, needsLogin: true}'
  exit 0
}

unifi_require_commands() {
  local cmd
  for cmd in curl jq secret-tool; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
  done
}

# The Integration API lives under /proxy/network on a UniFi OS console (UDM,
# UCG, Cloud Key Gen2+) and directly under the root on a self-hosted Network
# Application. A URL that already names the API path is used as given, so an
# unusual deployment can still be reached.
unifi_api_base_for() {
  local url="${1%/}"
  case "$url" in
    */integration/v1) printf '%s' "$url" ;;
    *) printf '%s/proxy/network/integration/v1' "$url" ;;
  esac
}

unifi_load_config() {
  [[ -r $UNIFI_CONFIG_FILE ]] || return 1
  local key value
  # shellcheck disable=SC2034  # UNIFI_SITE is read by unifi-fetch and unifi-login
  while IFS='=' read -r key value; do
    case "$key" in
      url) UNIFI_URL="$value" ;;
      site) UNIFI_SITE="$value" ;;
      insecure) UNIFI_INSECURE="$value" ;;
    esac
  done <"$UNIFI_CONFIG_FILE"
  [[ -n $UNIFI_URL ]] || return 1
  UNIFI_API_BASE="$(unifi_api_base_for "$UNIFI_URL")"
  return 0
}

unifi_save_config() { # url site insecure
  umask 077
  mkdir -p "$UNIFI_STATE_DIR"
  printf 'url=%s\nsite=%s\ninsecure=%s\n' "$1" "$2" "$3" >"$UNIFI_CONFIG_FILE"
}

unifi_api_key() {
  secret-tool lookup application "$UNIFI_PLUGIN_ID" type api-key 2>/dev/null
}

unifi_store_api_key() { # key on stdin
  secret-tool store --label="UniFi API key (Omarchy plugin)" \
    application "$UNIFI_PLUGIN_ID" type api-key
}

unifi_clear_api_key() {
  secret-tool clear application "$UNIFI_PLUGIN_ID" type api-key 2>/dev/null || true
}

# One request against the API. Sets UNIFI_HTTP_CODE and UNIFI_HTTP_BODY in the
# caller's shell; call it directly, not inside $(...). The API key is passed
# as a header line inside the curl config on stdin, never as an argument.
unifi_http() { # path-with-query api-key
  local config response
  config=$(printf 'url = "%s%s"\nheader = "X-API-KEY: %s"\nheader = "Accept: application/json"\nsilent\nshow-error\n' \
    "$UNIFI_API_BASE" "$1" "$2")
  [[ $UNIFI_INSECURE == 1 ]] && config+=$'\ninsecure'
  response=$(printf '%s\n' "$config" | curl --config - -m 20 -w '\n%{http_code}' 2>&1)
  UNIFI_HTTP_CODE=$(tail -n1 <<<"$response")
  UNIFI_HTTP_BODY=$(sed '$d' <<<"$response")
}

# A POST with a JSON body to an absolute URL, same conventions as unifi_http.
# Used for the classic report API, which lives beside the Integration API
# rather than under it.
unifi_http_post() { # url json-body api-key
  local config response
  config=$(printf 'url = "%s"\nheader = "X-API-KEY: %s"\nheader = "Accept: application/json"\nheader = "Content-Type: application/json"\ndata = %s\nsilent\nshow-error\n' \
    "$1" "$3" "$2")
  [[ $UNIFI_INSECURE == 1 ]] && config+=$'\ninsecure'
  response=$(printf '%s\n' "$config" | curl --config - -m 20 -w '\n%{http_code}' 2>&1)
  UNIFI_HTTP_CODE=$(tail -n1 <<<"$response")
  UNIFI_HTTP_BODY=$(sed '$d' <<<"$response")
}

# The classic Network API root that pairs with the Integration API base:
# …/proxy/network/integration/v1 → …/proxy/network, and on a self-hosted
# controller https://host:8443/integration/v1 → https://host:8443.
unifi_classic_base() {
  printf '%s' "${UNIFI_API_BASE%/integration/v1}"
}

# Turn a non-200 answer into a message the panel can show.
unifi_describe_http_failure() {
  case "$UNIFI_HTTP_CODE" in
    200) return 1 ;;
    401|403) printf 'The controller rejected the API key' ;;
    404) printf 'No Integration API at %s (Network 9.0 or newer is required)' "$UNIFI_API_BASE" ;;
    429) printf 'The controller is rate limiting requests' ;;
    000)
      # curl itself failed; its stderr is what we captured as the body.
      local reason
      reason=$(head -n1 <<<"$UNIFI_HTTP_BODY" | sed 's/^curl: ([0-9]*) //')
      case "$reason" in
        *"certificate"*|*"SSL"*)
          printf 'TLS verification failed — re-run unifi-login and allow the self-signed certificate' ;;
        "") printf 'Could not reach %s' "$UNIFI_URL" ;;
        *) printf 'Could not reach %s: %s' "$UNIFI_URL" "$reason" ;;
      esac ;;
    *) printf 'The controller returned HTTP %s' "$UNIFI_HTTP_CODE" ;;
  esac
}
