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
# refresh the scripts configmap with the latest opencode policy
oc -n fullsend create configmap fullsend-runner-scripts \
  --from-file=openshell-auth.sh="$D/scripts/openshell-auth.sh" \
  --from-file=run-agent.sh="$D/scripts/run-agent.sh" \
  --from-file=smoke.sh="$D/scripts/smoke.sh" \
  --from-file=debug-gateway.sh="$D/scripts/debug-gateway.sh" \
  --from-file=debug-profile.sh="$D/scripts/debug-profile.sh" \
  --from-file=debug-ca.sh="$D/scripts/debug-ca.sh" \
  --from-file=opencode-config.json="$D/opencode-config.json" \
  --from-file=base-policy.yaml="$D/scripts/base-policy.yaml" \
  --dry-run=client -o yaml | oc -n fullsend apply -f - >/dev/null
echo "scripts configmap refreshed"

oc -n fullsend delete pod outview --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/outview-pod.yaml" >/dev/null
for i in $(seq 1 20); do
  p=$(oc -n fullsend get pod outview -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$p" = "Running" ] || [ "$p" = "Succeeded" ] && break
  sleep 4
done
echo "== run tree =="
oc -n fullsend exec outview -- find /out/fs-tri-9cb6ea94bff8 -maxdepth 3 -type f 2>&1 | head -20
echo "== agent-result.json =="
oc -n fullsend exec outview -- cat /out/fs-tri-9cb6ea94bff8/iteration-1/output/agent-result.json 2>&1 | head -60
echo "== metrics.json =="
oc -n fullsend exec outview -- cat /out/fs-tri-9cb6ea94bff8/metrics.json 2>&1 | head -30
oc -n fullsend delete pod outview --ignore-not-found >/dev/null
for j in profdebug cadebug; do oc -n fullsend delete job "$j" --ignore-not-found >/dev/null; done
