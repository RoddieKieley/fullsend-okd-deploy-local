#!/usr/bin/env bash
# Shared OpenShell gateway auth for in-cluster fullsend runs.
#
# The OpenShell CLI has no non-interactive login: `gateway login` is a browser
# flow and the stored credential file is just {access_token, issuer,
# client_id}. We mint that token ourselves with a Keycloak service account and
# refresh it in the background before it expires.
#
# Required env:
#   KEYCLOAK_CLIENT_SECRET   client secret for the `fullsend-runner` client
# Optional env:
#   KEYCLOAK_TOKEN_URL       default: the hypershell realm token endpoint
#   OPENSHELL_GATEWAY_URL    default: the OKD gateway route
#   OPENSHELL_GATEWAY_NAME   default: okd
set -euo pipefail

KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL:-https://keycloak-hypershell-keycloak.apps.<cluster-domain>/realms/hypershell/protocol/openid-connect/token}"
OPENSHELL_GATEWAY_NAME="${OPENSHELL_GATEWAY_NAME:-okd}"
# The gateway is recreated with a new ID/hostname by the hypershell controller;
# `gw-discover.sh` rewrites the metadata below. Prefer that over a hardcoded
# default so a rotation only needs one discovery run. In-cluster callers set
# OPENSHELL_GATEWAY_URL to the Service endpoint and override this anyway.
if [[ -z "${OPENSHELL_GATEWAY_URL:-}" ]]; then
  _meta="$HOME/.config/openshell/gateways/$OPENSHELL_GATEWAY_NAME/metadata.json"
  if [[ -f "$_meta" ]]; then
    OPENSHELL_GATEWAY_URL=$(jq -r '.gateway_endpoint // empty' "$_meta" 2>/dev/null)
  fi
fi
OPENSHELL_GATEWAY_URL="${OPENSHELL_GATEWAY_URL:-https://gw-<openshell-namespace>.gw.<cluster-domain>}"
OPENSHELL_OIDC_ISSUER="${OPENSHELL_OIDC_ISSUER:-https://keycloak-hypershell-keycloak.apps.<cluster-domain>/realms/hypershell}"
if [[ -z "${OPENSHELL_OIDC_CLIENT_ID:-}" && -f "${_meta:-}" ]]; then
  OPENSHELL_OIDC_CLIENT_ID=$(jq -r '.oidc_client_id // empty' "$_meta" 2>/dev/null)
fi
OPENSHELL_OIDC_CLIENT_ID="${OPENSHELL_OIDC_CLIENT_ID:-3LvCTLg6l3GG1XNl1Z3N5ZWXNKe}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-fullsend-runner}"

a2en_gateway_dir() {
  mkdir -p "$HOME/.config/openshell/gateways/$OPENSHELL_GATEWAY_NAME"
}

fetch_access_token() {
  curl -fsS -X POST "$KEYCLOAK_TOKEN_URL" \
    -d grant_type=client_credentials \
    -d client_id="$KEYCLOAK_CLIENT_ID" \
    --data-urlencode "client_secret=${KEYCLOAK_CLIENT_SECRET:?KEYCLOAK_CLIENT_SECRET must be set}" \
    | jq -er .access_token
}

write_gateway_credentials() {
  local token="$1" dir="$HOME/.config/openshell/gateways/$OPENSHELL_GATEWAY_NAME"
  a2en_gateway_dir
  jq -n --arg t "$token" --arg i "$OPENSHELL_OIDC_ISSUER" --arg c "$OPENSHELL_OIDC_CLIENT_ID" \
    '{access_token:$t, issuer:$i, client_id:$c}' > "$dir/oidc_token.json.tmp"
  chmod 600 "$dir/oidc_token.json.tmp"
  mv "$dir/oidc_token.json.tmp" "$dir/oidc_token.json"
  jq -n --arg e "$OPENSHELL_GATEWAY_URL" --arg i "$OPENSHELL_OIDC_ISSUER" --arg c "$OPENSHELL_OIDC_CLIENT_ID" --arg n "$OPENSHELL_GATEWAY_NAME" \
    '{name:$n, gateway_endpoint:$e, is_remote:true, gateway_port:0, auth_mode:"oidc", oidc_issuer:$i, oidc_client_id:$c}' \
    > "$dir/metadata.json"
}

# Refresh every 4 minutes; Keycloak's default access-token lifespan is 5.
start_token_refresher() {
  # The redirection must be *inside* the subshell: without it the background
  # process inherits the caller's command-substitution pipe and keeps it open,
  # so `PID=$(start_token_refresher)` never returns.
  ( while sleep 240; do
      if tok=$(fetch_access_token 2>/dev/null); then
        write_gateway_credentials "$tok"
      fi
    done ) >/dev/null 2>&1 &
  echo $!
}

openshell_auth_init() {
  local tok
  tok=$(fetch_access_token)
  write_gateway_credentials "$tok"
  export OPENSHELL_GATEWAY="$OPENSHELL_GATEWAY_NAME"
  openshell gateway select "$OPENSHELL_GATEWAY_NAME" >/dev/null
  # Exported so a caller (e.g. the host wrapper) can stop the refresher.
  OPENSHELL_TOKEN_REFRESHER_PID=$(start_token_refresher)
  export OPENSHELL_TOKEN_REFRESHER_PID
}
