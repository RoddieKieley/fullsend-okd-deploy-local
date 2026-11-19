#!/usr/bin/env bash
# Re-run triage against the private GitHub scratch repo and verify the result.
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
LOG="$T/gh-retriage.log"
: > "$LOG"
exec >> "$LOG" 2>&1

TOK=$(sed -n 's/^GH_TOKEN=//p' "$T/gh.env" | head -1)

echo "== issue BEFORE =="
GH_TOKEN="$TOK" gh issue view 1 --repo ${PROBE_REPO} \
  --json title,state,labels --jq '{title, state, labels: [.labels[].name]}' 2>&1

oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/job-triage.yaml"

for i in $(seq 1 150); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 10
done

echo "== job logs (tail) =="
oc -n fullsend logs job/fullsend-triage --tail=80

echo "== issue AFTER =="
GH_TOKEN="$TOK" gh issue view 1 --repo ${PROBE_REPO} \
  --json title,state,labels --jq '{title, state, labels: [.labels[].name]}' 2>&1
echo "--- last comment ---"
GH_TOKEN="$TOK" gh issue view 1 --repo ${PROBE_REPO} \
  --json comments --jq '.comments[-1] | "\(.author.login): \(.body[0:600])"' 2>&1
echo RETRIAGE_DONE
