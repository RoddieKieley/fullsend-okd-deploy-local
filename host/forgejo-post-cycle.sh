#!/usr/bin/env bash
# Re-run the triage Job with the post-script enabled and verify Forgejo state.
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
LOG="$T/forgejo-post.log"
: > "$LOG"
exec >> "$LOG" 2>&1

set -a; source "$T/forgejo.env"; set +a

echo "== issue BEFORE =="
curl -fsS -H "Authorization: token $FORGEJO_TOKEN" \
  "$FORGEJO_URL/api/v1/repos/${FORGEJO_PROBE_REPO:-${PROBE_REPO}}/issues/${PROBE_ISSUE}" \
  | jq '{state, labels: [.labels[].name]}'

oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/job-triage.yaml"

for i in $(seq 1 150); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 10
done

echo "== job logs (tail) =="
oc -n fullsend logs job/fullsend-triage --tail=60

echo "== issue AFTER =="
curl -fsS -H "Authorization: token $FORGEJO_TOKEN" \
  "$FORGEJO_URL/api/v1/repos/${FORGEJO_PROBE_REPO:-${PROBE_REPO}}/issues/${PROBE_ISSUE}" \
  | jq '{state, labels: [.labels[].name]}'
echo "--- comments ---"
curl -fsS -H "Authorization: token $FORGEJO_TOKEN" \
  "$FORGEJO_URL/api/v1/repos/${FORGEJO_PROBE_REPO:-${PROBE_REPO}}/issues/${PROBE_ISSUE}/comments" \
  | jq -r '.[] | "\(.user.login): \(.body[0:400])"'
echo POST_DONE
