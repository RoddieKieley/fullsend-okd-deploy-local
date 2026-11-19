#!/usr/bin/env bash
# shellcheck shell=bash
# values.sh — load portable OKD deployment values.
#
# Precedence (highest first):
#   1. process environment
#   2. values.local.env          (git-ignored; per-cluster, may hold identifiers)
#   3. values.example.env        (committed defaults)
#
# Values are plain assignments: no secrets. Credentials come from Kubernetes
# Secrets or from files named by *_FILE variables. Every value is exported so
# renderers (envsubst) and child processes see the same view.
#
# Usage:
#   OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
#   . "$OKD_ROOT/scripts/lib/values.sh"
#   okd_require CLUSTER_DOMAIN || exit 1

OKD_ROOT=${OKD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
export OKD_ROOT

declare -A _OKD_VALUES=()

_okd_parse() { # $1 file — later files override earlier ones in the map
  local f=$1 line k v
  [[ -r $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line == *=* ]] || continue
    k=${line%%=*}
    v=${line#*=}
    k=${k//[[:space:]]/}
    [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ ${#v} -ge 2 && ${v:0:1} == '"' && ${v: -1} == '"' ]]; then v=${v:1:-1}; fi
    if [[ ${#v} -ge 2 && ${v:0:1} == "'" && ${v: -1} == "'" ]]; then v=${v:1:-1}; fi
    _OKD_VALUES[$k]=$v
  done <"$f"
}

_okd_parse "$OKD_ROOT/values.example.env"
_okd_parse "${OKD_VALUES_FILE:-$OKD_ROOT/values.local.env}"

for _k in "${!_OKD_VALUES[@]}"; do
  # The process environment wins over both files.
  [[ -n ${!_k:-} ]] || printf -v "$_k" '%s' "${_OKD_VALUES[$_k]}"
  export "${_k?}"
done
unset _k _OKD_VALUES

# ---------------------------------------------------------------- derived ----
: "${NAMESPACE:=fullsend}"
: "${INFERENCE_NAMESPACE:=fullsend-inference}"
: "${IMAGE_NAMESPACE:=$NAMESPACE}"
: "${KEYCLOAK_REALM:=hypershell}"
: "${KEYCLOAK_CLIENT_ID:=fullsend-runner}"
: "${OPENSHELL_GATEWAY_NAME:=okd}"
: "${GITHUB_APP_SECRET_NAME:=fullsend-github-app}"
: "${ENMAAS_API_KEY_SECRET:=enmaas-api-key}"
: "${GITHUB_APP_PRIVATE_KEY_FILE:=/var/run/secrets/github-app/private-key}"
: "${FULLSEND_MAX_CONCURRENT_TRIAGE:=4}"
: "${FULLSEND_MAX_CONCURRENT_CODE:=4}"
: "${IN_CLUSTER_REGISTRY:=image-registry.openshift-image-registry.svc:5000}"

if [[ -n ${CLUSTER_DOMAIN:-} ]]; then
  : "${KEYCLOAK_HOST:=keycloak-hypershell-keycloak.apps.$CLUSTER_DOMAIN}"
  : "${REGISTRY:=default-route-openshift-image-registry.apps.$CLUSTER_DOMAIN}"
fi
if [[ -n ${KEYCLOAK_HOST:-} ]]; then
  : "${KEYCLOAK_TOKEN_URL:=https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM/protocol/openid-connect/token}"
  : "${OPENSHELL_OIDC_ISSUER:=https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM}"
fi
if [[ -n ${OPENSHELL_NAMESPACE:-} ]]; then
  : "${OPENSHELL_GATEWAY_URL:=https://openshell-gateway.${OPENSHELL_NAMESPACE}.svc.cluster.local:8080}"
fi
: "${RUNNER_IMAGE:=${IN_CLUSTER_REGISTRY}/${IMAGE_NAMESPACE}/fullsend-runner-okd:dev}"
: "${CODE_IMAGE:=${IN_CLUSTER_REGISTRY}/${IMAGE_NAMESPACE}/fullsend-code-okd:dev}"

export NAMESPACE INFERENCE_NAMESPACE IMAGE_NAMESPACE KEYCLOAK_REALM KEYCLOAK_CLIENT_ID \
       OPENSHELL_GATEWAY_NAME GITHUB_APP_SECRET_NAME GITHUB_APP_PRIVATE_KEY_FILE ENMAAS_API_KEY_SECRET \
       FULLSEND_MAX_CONCURRENT_TRIAGE FULLSEND_MAX_CONCURRENT_CODE IN_CLUSTER_REGISTRY SANDBOX_IMAGE \
       KEYCLOAK_HOST REGISTRY KEYCLOAK_TOKEN_URL OPENSHELL_OIDC_ISSUER \
       OPENSHELL_GATEWAY_URL RUNNER_IMAGE CODE_IMAGE LITELLM_MODEL_QWEN_UPSTREAM AGENTS_WORKTREE PROBE_REPO PROBE_ISSUE

# okd_require VAR [VAR...] — fail with a single clear message.
okd_require() {
  local missing="" v
  for v in "$@"; do
    [[ -n ${!v:-} ]] || missing+="${missing:+ }$v"
  done
  [[ -z $missing ]] && return 0
  echo "values: required and unset: $missing (set in values.local.env or the environment)" >&2
  return 1
}

# okd_require_cluster — the variables every deployment needs.
okd_require_cluster() {
  okd_require CLUSTER_DOMAIN NAMESPACE INFERENCE_NAMESPACE REGISTRY IN_CLUSTER_REGISTRY \
              OPENSHELL_NAMESPACE OPENSHELL_GATEWAY_URL KEYCLOAK_HOST KEYCLOAK_REALM \
              KEYCLOAK_CLIENT_ID OPENSHELL_OIDC_CLIENT_ID OPENSHELL_OIDC_ISSUER \
              MODEL_API_BASE MODEL_TRIAGE MODEL_CODE GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID
}
