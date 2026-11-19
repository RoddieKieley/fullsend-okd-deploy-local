#!/usr/bin/env bash
set -uo pipefail
HOST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OKD_ROOT=$(dirname "$HOST_DIR")
D="$OKD_ROOT"
T="${SECRETS_DIR:-}"
. "$OKD_ROOT/scripts/lib/values.sh"
: "${SECRETS_DIR:?SECRETS_DIR must be set (values.local.env)}"
T="$SECRETS_DIR"
ORG="${WORKSPACE_ROOT:-$(dirname "$(dirname "$OKD_ROOT")")}"

bash "$HOST_DIR/render-manifests.sh" >/dev/null 2>&1 || true
oc -n fullsend delete pod outview --ignore-not-found >/dev/null 2>&1
oc -n fullsend apply -f "$D/k8s/rendered/outview-result.yaml" >/dev/null
for i in $(seq 1 30); do
  p=$(oc -n fullsend get pod outview -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$p" == "Succeeded" || "$p" == "Failed" ]] && break
  sleep 3
done
oc -n fullsend logs outview 2>&1 | head -40
oc -n fullsend delete pod outview --ignore-not-found >/dev/null 2>&1
