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
LOG=$T/post-run.log
: > "$LOG"
TOK=$(sed -n 's/^GH_TOKEN=//p' "$T/gh.env" | head -1)

echo "== issue BEFORE ==" >> "$LOG"
GH_TOKEN="$TOK" gh issue view 1 --repo ${PROBE_REPO} --json state,labels,comments \
  --jq '{state, labels: [.labels[].name], comments: [.comments[] | {author: .author.login, body: (.body[0:120])}]}' >> "$LOG" 2>&1

oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f $OKD_ROOT/k8s/rendered/job-triage.yaml >> "$LOG" 2>&1
for i in $(seq 1 90); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}" >> "$LOG"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 10
done
echo "== job logs (tail) ==" >> "$LOG"
oc -n fullsend logs job/fullsend-triage --tail=60 >> "$LOG" 2>&1
echo "== issue AFTER ==" >> "$LOG"
GH_TOKEN="$TOK" gh issue view 1 --repo ${PROBE_REPO} --json state,labels,comments \
  --jq '{state, labels: [.labels[].name], comments: [.comments[] | {author: .author.login, body: (.body[0:200])}]}' >> "$LOG" 2>&1
echo POST_RUN_DONE >> "$LOG"
