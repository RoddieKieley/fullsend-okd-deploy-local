#!/usr/bin/env bash
# no-local-identifiers.sh — fail when a tracked file embeds a value that must
# stay local (values.local.env).
#
# Compares the tracked tree against the real values: GitHub App id and
# installation id, cluster domain, OpenShell namespace, Keycloak host, LiteLLM
# route, EnMaaS endpoint and the local model host. Only file names are printed,
# never the values.
#
# Run from anywhere: bash tests/no-local-identifiers.sh
set -uo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh" 2>/dev/null || {
  echo "no values available (values.local.env absent) — skipping identifier check"
  exit 0
}
cd "$OKD_ROOT" || exit 1

values=()
add() { [[ -n ${1:-} ]] && values+=("$1"); }
add "${GITHUB_APP_ID:-}"
add "${GITHUB_APP_INSTALLATION_ID:-}"
add "${CLUSTER_DOMAIN:-}"
add "${OPENSHELL_NAMESPACE:-}"
add "${KEYCLOAK_HOST:-}"
add "${LITELLM_ROUTE:-}"
add "${ENMAAS_API_BASE:-}"
model_host=$(printf '%s' "${MODEL_API_BASE:-}" | sed -E 's|^[a-z]+://||; s|[:/].*$||')
add "$model_host"

fail=0
for v in "${values[@]}"; do
  [[ ${#v} -ge 4 ]] || continue          # ignore trivial values
  hits=$(git ls-files -z | xargs -0 grep -lF -- "$v" 2>/dev/null || true)
  if [[ -n $hits ]]; then
    echo "FAIL: tracked file(s) contain a local identifier (value length ${#v}):" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    fail=1
  fi
done


# Generic private-network / cluster patterns: never in a public repo.
generic=(
  '\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b'
  '\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b'
  '\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b'
  'openshell-[0-9a-f]{12,}'
)
for pat in "${generic[@]}"; do
  hits=$(git grep -lE -- "$pat" -- . 2>/dev/null || true)
  if [[ -n $hits ]]; then
    echo "FAIL: tracked file(s) match a private-network pattern:" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    fail=1
  fi
done

[[ $fail -eq 0 ]] && echo "ok: no local identifiers in tracked files"
exit "$fail"
