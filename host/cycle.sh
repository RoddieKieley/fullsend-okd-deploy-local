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
echo "===== 1. rebuild + push ====="
bash $HOST_DIR/rebuild-runner.sh 2>&1 | tail -4
bash $HOST_DIR/push-runner-image.sh 2>&1 | tail -3

echo "===== 2. gateway cleanup ====="
bash $HOST_DIR/full-cleanup.sh 2>&1 | tail -12

echo "===== 3. run job ====="
oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f $OKD_ROOT/k8s/rendered/job-triage.yaml
for i in $(seq 1 70); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 10
done
echo "===== 4. logs ====="
oc -n fullsend logs job/fullsend-triage --tail=80 2>&1
