#!/usr/bin/env bash
# rotate-enmaas-key.sh — store a new EnMaaS API key and make LiteLLM use it.
#
# A Secret update alone is NOT enough: LiteLLM reads ENMAAS_API_KEY from its
# environment at container start, so the Deployment must be rolled. This script
# does both and verifies the running pod carries the new key (hash comparison,
# never printing the value).
#
# Usage:
#   rotate-enmaas-key.sh <key-file>          # file contains only the key
#   ENMAAS_API_KEY=... rotate-enmaas-key.sh  # or pass it in the environment
set -euo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"
okd_require INFERENCE_NAMESPACE ENMAAS_API_BASE || exit 1

NS="$INFERENCE_NAMESPACE"
key_hash() { sha256sum | cut -c1-12; }

if [[ -n "${1:-}" ]]; then
  [[ -r $1 ]] || { echo "cannot read key file: $1" >&2; exit 1; }
  KEY=$(tr -d '[:space:]' <"$1")
else
  KEY="${ENMAAS_API_KEY:-}"
fi
[[ -n $KEY ]] || { echo "no key: pass a file or set ENMAAS_API_KEY" >&2; exit 1; }

echo "== update Secret/${ENMAAS_API_KEY_SECRET:-enmaas-api-key} =="
oc -n "$NS" create secret generic "${ENMAAS_API_KEY_SECRET:-enmaas-api-key}" \
  --from-literal=api-key="$KEY" --dry-run=client -o yaml | oc -n "$NS" apply -f -

echo "== restart LiteLLM (it caches env at startup) =="
oc -n "$NS" rollout restart deploy/litellm >/dev/null
oc -n "$NS" rollout status deploy/litellm --timeout=300s 2>&1 | tail -1

echo "== verify the pod carries the new key =="
secret_sha=$(oc -n "$NS" get secret "${ENMAAS_API_KEY_SECRET:-enmaas-api-key}" -o jsonpath='{.data.api-key}' | base64 -d | key_hash)
pod_sha=$(oc -n "$NS" exec deploy/litellm -- printenv ENMAAS_API_KEY | tr -d '\n' | key_hash)
if [[ $secret_sha == "$pod_sha" ]]; then
  echo "  ok: secreted and running key match ($secret_sha)"
else
  echo "  MISMATCH: secret=$secret_sha pod=$pod_sha" >&2
  exit 1
fi

if [[ -x "$OKD_ROOT/../scripts/probe-enmaas.sh" ]]; then
  echo "== probe =="
  bash "$OKD_ROOT/../scripts/probe-enmaas.sh"
fi
