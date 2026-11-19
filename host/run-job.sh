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

oc -n fullsend create configmap fullsend-runner-scripts \
  --from-file=openshell-auth.sh="$D/scripts/openshell-auth.sh" \
  --from-file=run-agent.sh="$D/scripts/run-agent.sh" \
  --from-file=smoke.sh="$D/scripts/smoke.sh" \
  --from-file=debug-gateway.sh="$D/scripts/debug-gateway.sh" \
  --from-file=opencode-config.json="$D/opencode-config.json" \
  --from-file=base-policy.yaml="$D/scripts/base-policy.yaml" \
  --dry-run=client -o yaml | oc -n fullsend apply -f - >/dev/null

# Keep the k8s secret in step with the host env file.
TOK=$(sed -n 's/^GH_TOKEN=//p' $T/gh.env | head -1)
if [[ -n "$TOK" ]]; then
  oc -n fullsend create secret generic fullsend-github --from-literal=token="$TOK" \
    --dry-run=client -o yaml | oc -n fullsend apply -f - >/dev/null
  echo "github secret synced from gh.env"
fi

oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/job-triage.yaml"
sleep 10
oc -n fullsend get pods -l app=fullsend-agent -o wide 2>&1 | tail -3
