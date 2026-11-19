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

echo "== shell syntax =="
bash -n "$D/scripts/run-agent.sh" && echo "run-agent.sh OK"
bash -n "$D/scripts/openshell-auth.sh" && echo "openshell-auth.sh OK"

echo "== cleanup old jobs =="
for j in netcheck gwcheck ollamacheck ollamalist chatcheck gwdebug smoke; do
  oc -n fullsend delete job "$j" --ignore-not-found >/dev/null 2>&1
done
oc -n fullsend get jobs 2>&1

echo "== output PVC =="
oc -n fullsend get pvc fullsend-output >/dev/null 2>&1 || cat <<YAML | oc -n fullsend apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fullsend-output
  namespace: fullsend
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 2Gi
YAML

echo "== github secret placeholder (replace token when available) =="
oc -n fullsend get secret fullsend-github >/dev/null 2>&1 || \
  oc -n fullsend create secret generic fullsend-github --from-literal=token=REPLACE_ME

echo "== dry-run job manifests =="
oc -n fullsend apply --dry-run=server -f "$D/k8s/rendered/job-triage.yaml" 2>&1 | tail -5

echo "== namespace inventory =="
oc -n fullsend get sa,secret,pvc,cm,imagestream 2>&1 | head -25
