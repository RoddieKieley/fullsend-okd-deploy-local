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

oc -n fullsend apply -f "$D/k8s/rendered/00-runner-base.yaml"
oc -n fullsend create configmap fullsend-runner-scripts \
  --from-file=openshell-auth.sh="$D/scripts/openshell-auth.sh" \
  --from-file=smoke.sh="$D/scripts/smoke.sh" \
  --dry-run=client -o yaml | oc -n fullsend apply -f -
oc -n fullsend create secret generic fullsend-runner-keycloak \
  --from-file=client-secret=$T/fullsend-runner-client-secret \
  --dry-run=client -o yaml | oc -n fullsend apply -f -

oc -n fullsend delete job smoke --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/smoke-job.yaml"
echo "== pods =="
sleep 20
oc -n fullsend get pods -l app=fullsend-smoke -o wide
echo "== events (if pending) =="
oc -n fullsend describe job smoke 2>&1 | tail -15
echo "== logs =="
oc -n fullsend logs job/smoke 2>&1 | tail -50
