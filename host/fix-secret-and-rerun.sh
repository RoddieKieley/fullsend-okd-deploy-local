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
S=$(cat $T/fullsend-runner-client-secret)
oc -n fullsend create secret generic fullsend-runner-keycloak \
  --from-literal="client-secret=$S" --dry-run=client -o yaml | oc -n fullsend apply -f -
oc -n fullsend delete job smoke --ignore-not-found >/dev/null
oc -n fullsend apply -f $OKD_ROOT/k8s/rendered/smoke-job.yaml
for i in $(seq 1 30); do
  st=$(oc -n fullsend get pods -l app=fullsend-smoke --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 10
done
echo "== logs =="
oc -n fullsend logs job/smoke --tail=120 2>&1
