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
LOG="$T/dispatcher-deploy.log"
: > "$LOG"
exec >> "$LOG" 2>&1

echo "===== 1. scripts configmap ====="
oc -n "$NS" create configmap fullsend-dispatcher \
  --from-file=dispatch-code.sh="$D/dispatcher/dispatch-code.sh" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -

echo "===== 2. rbac + cronjob ====="
"$D/host/render-manifests.sh" >/dev/null
oc -n "$NS" apply -f "$D/k8s/rendered/dispatcher.yaml"

echo "===== 3. dry run ====="
oc -n "$NS" delete job dispatcher-dryrun --ignore-not-found >/dev/null
oc -n "$NS" apply -f "$D/k8s/rendered/dispatcher-dryrun.yaml"
for i in $(seq 1 30); do
  st=$(oc -n "$NS" get pods -l job-name=dispatcher-dryrun --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 4
done
oc -n "$NS" logs job/dispatcher-dryrun 2>&1
oc -n "$NS" delete job dispatcher-dryrun --ignore-not-found >/dev/null
