#!/usr/bin/env bash
# Run the code agent on pi through the LiteLLM inference gateway.
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
LOG="$T/pi-code.log"
: > "$LOG"
exec >> "$LOG" 2>&1

set -a; source "$T/gh.env"; source "$T/litellm.env"; set +a

echo "===== 1. lint code harness ====="
cd $ORG/fullsend
${FULLSEND_BIN:?FULLSEND_BIN must be set} lint code --forge github --fullsend-dir ${AGENTS_WORKTREE:?AGENTS_WORKTREE must be set} 2>&1 | tail -12
echo "lint_exit=${PIPESTATUS[0]}"

echo "===== 2. inference key into fullsend ns ====="
oc -n fullsend create secret generic litellm-inference-key \
  --from-literal=api-key="$LITELLM_MASTER_KEY" \
  --dry-run=client -o yaml | oc -n fullsend apply -f -

echo "===== 3. scripts configmap ====="
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

echo "===== 4. rebuild + push runner image ====="
bash $HOST_DIR/rebuild-runner.sh 2>&1 | tail -3
bash $HOST_DIR/push-runner-image.sh 2>&1 | tail -3

echo "===== 5. label the issue ready-to-code ====="
GH_TOKEN="$GH_TOKEN" gh issue edit 1 --repo ${PROBE_REPO} --add-label ready-to-code 2>&1 | tail -2
GH_TOKEN="$GH_TOKEN" gh issue view 1 --repo ${PROBE_REPO} --json labels --jq '[.labels[].name]' 2>&1

echo "===== 6. apply code job ====="
oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/job-triage.yaml"

echo "===== 7. watch ====="
for i in $(seq 1 220); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 20
done

echo "===== 8. logs ====="
oc -n fullsend logs job/fullsend-triage --tail=120

echo "===== 9. repo state ====="
GH_TOKEN="$GH_TOKEN" gh issue view 1 --repo ${PROBE_REPO} --json state,labels --jq '{state, labels: [.labels[].name]}' 2>&1
GH_TOKEN="$GH_TOKEN" gh pr list --repo ${PROBE_REPO} --state all --json number,title,headRefName,url --limit 10 2>&1
GH_TOKEN="$GH_TOKEN" gh api repos/${PROBE_REPO}/branches --jq '.[].name' 2>&1
echo PI_CODE_DONE
