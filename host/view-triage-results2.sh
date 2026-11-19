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
NS="$NAMESPACE"

bash "$HOST_DIR/render-manifests.sh" >/dev/null 2>&1 || true
oc -n fullsend delete job outview --ignore-not-found >/dev/null 2>&1
oc -n fullsend apply -f "$D/k8s/rendered/outview-job.yaml" >/dev/null
for i in $(seq 1 40); do
  st=$(oc -n fullsend get pods -l job-name=outview --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 3
done
oc -n fullsend logs job/outview 2>&1 | head -50
oc -n fullsend delete job outview --ignore-not-found >/dev/null 2>&1
