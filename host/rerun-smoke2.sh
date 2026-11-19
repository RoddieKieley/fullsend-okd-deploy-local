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
oc -n fullsend create configmap fullsend-runner-scripts \
  --from-file=openshell-auth.sh="$D/scripts/openshell-auth.sh" \
  --from-file=smoke.sh="$D/scripts/smoke.sh" \
  --from-file=base-policy.yaml="$D/scripts/base-policy.yaml" \
  --from-file=debug-gateway.sh="$D/scripts/debug-gateway.sh" \
  --dry-run=client -o yaml | oc -n fullsend apply -f - >/dev/null
oc -n fullsend delete job smoke --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/smoke-job.yaml" >/dev/null
for i in $(seq 1 50); do
  st=$(oc -n fullsend get pods -l app=fullsend-smoke --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 8
done
echo "== logs =="
oc -n fullsend logs job/smoke --tail=200 2>&1
