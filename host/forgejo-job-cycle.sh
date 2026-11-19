#!/usr/bin/env bash
# Forgejo end-to-end cycle: secret, configmap, image, Job, watch.
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
LOG="$T/forgejo-job.log"
: > "$LOG"
exec >> "$LOG" 2>&1

echo "===== 1. forgejo secret ====="
set -a; source "$T/forgejo.env"; set +a
oc -n fullsend create secret generic fullsend-forgejo --from-literal=token="$FORGEJO_TOKEN" \
  --dry-run=client -o yaml | oc -n fullsend apply -f -

echo "===== 2. scripts configmap ====="
oc -n fullsend create configmap fullsend-runner-scripts \
  --from-file=openshell-auth.sh="$D/scripts/openshell-auth.sh" \
  --from-file=run-agent.sh="$D/scripts/run-agent.sh" \
  --from-file=smoke.sh="$D/scripts/smoke.sh" \
  --from-file=debug-gateway.sh="$D/scripts/debug-gateway.sh" \
  --from-file=debug-profile.sh="$D/scripts/debug-profile.sh" \
  --from-file=debug-ca.sh="$D/scripts/debug-ca.sh" \
  --from-file=opencode-config.json="$D/opencode-config.json" \
  --from-file=base-policy.yaml="$D/scripts/base-policy.yaml" \
  --dry-run=client -o yaml | oc -n fullsend apply -f -

echo "===== 3. rebuild + push image ====="
bash $HOST_DIR/rebuild-runner.sh 2>&1 | tail -3
bash $HOST_DIR/push-runner-image.sh 2>&1 | tail -3

echo "===== 4. apply job ====="
oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/job-triage.yaml"

echo "===== 5. watch ====="
for i in $(seq 1 150); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 10
done

echo "===== 6. logs ====="
oc -n fullsend logs job/fullsend-triage --tail=120

echo "===== 7. issue state ====="
ISSUE=$(curl -fsS -H "Authorization: token $FORGEJO_TOKEN" \
  "$FORGEJO_URL/api/v1/repos/${FORGEJO_PROBE_REPO:-${PROBE_REPO}}/issues/${PROBE_ISSUE}")
echo "$ISSUE" | jq '{state, labels: [.labels[].name]}'
echo "--- comments ---"
curl -fsS -H "Authorization: token $FORGEJO_TOKEN" \
  "$FORGEJO_URL/api/v1/repos/${FORGEJO_PROBE_REPO:-${PROBE_REPO}}/issues/${PROBE_ISSUE}/comments" \
  | jq -r '.[] | "\(.user.login): \(.body[0:300])"'
echo DONE
