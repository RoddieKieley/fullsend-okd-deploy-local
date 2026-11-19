#!/usr/bin/env bash
# deploy-app-identity.sh — cut the OKD deployment over to GitHub App identity.
#
#  1. store the App credentials (app id, installation id, private key)
#  2. refresh the runner-scripts and dispatcher ConfigMaps
#  3. apply the dispatcher CronJob (App env + key mount, no PAT)
#  4. prove it: run the dispatcher once and check the identity line
#
# Idempotent. Logs to $SECRETS_DIR/app-cutover.log.
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

KEY=$T/fullsend-code.private-key.pem
APP_ID=${GITHUB_APP_ID}
INST=${GITHUB_APP_INSTALLATION_ID}
LOG=$T/app-cutover.log
: > "$LOG"
exec >> "$LOG" 2>&1

echo "===== 1. secret fullsend-github-app ====="
oc -n "$NS" create secret generic fullsend-github-app \
  --from-literal=app-id="$APP_ID" \
  --from-literal=installation-id="$INST" \
  --from-file=private-key="$KEY" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -
oc -n "$NS" get secret fullsend-github-app -o json | jq -r '"  keys: " + ([.data | keys[]] | join(","))'

echo "===== 2. configmaps ====="
oc -n "$NS" create configmap fullsend-runner-scripts \
  --from-file=openshell-auth.sh="$D/scripts/openshell-auth.sh" \
  --from-file=mint-app-token.sh="$D/scripts/mint-app-token.sh" \
  --from-file=run-agent.sh="$D/scripts/run-agent.sh" \
  --from-file=smoke.sh="$D/scripts/smoke.sh" \
  --from-file=debug-gateway.sh="$D/scripts/debug-gateway.sh" \
  --from-file=opencode-config.json="$D/opencode-config.json" \
  --from-file=base-policy.yaml="$D/scripts/base-policy.yaml" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -
oc -n "$NS" create configmap fullsend-dispatcher \
  --from-file=dispatch.sh="$D/dispatcher/dispatch.sh" \
  --from-file=dispatch-code.sh="$D/dispatcher/dispatch-code.sh" \
  --from-file=mint-app-token.sh="$D/scripts/mint-app-token.sh" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -

echo "===== 3. cronjob ====="
"$D/host/render-manifests.sh" >/dev/null
oc -n "$NS" apply -f "$D/k8s/rendered/dispatcher.yaml"
echo "-- env --"
oc -n "$NS" get cronjob fullsend-dispatch -o json \
  | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]
      | "  \(.name)=" + (.value // ("ref:" + (.valueFrom.secretKeyRef.name // "?") + "/" + (.valueFrom.secretKeyRef.key // "?")))'
echo "-- mounts --"
oc -n "$NS" get cronjob fullsend-dispatch -o json \
  | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] | "  \(.name) -> \(.mountPath)"'

echo "===== 4. one dispatcher run ====="
oc -n "$NS" delete job dispatcher-apptest --ignore-not-found >/dev/null
oc -n "$NS" create job dispatcher-apptest --from=cronjob/fullsend-dispatch >/dev/null
for _ in $(seq 1 40); do
  st=$(oc -n "$NS" get pods -l job-name=dispatcher-apptest --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 4
done
oc -n "$NS" logs job/dispatcher-apptest 2>&1 | head -20
echo "-- pod status --"
oc -n "$NS" get pods -l job-name=dispatcher-apptest --no-headers 2>/dev/null | awk '{print "  " $1, $3}'
