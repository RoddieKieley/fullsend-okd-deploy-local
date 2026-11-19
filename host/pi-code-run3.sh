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
LOG="$T/pi-code3.log"
: > "$LOG"
exec >> "$LOG" 2>&1

echo "===== clean stale sandboxes ====="
export KEYCLOAK_CLIENT_SECRET="$(cat "$T/fullsend-runner-client-secret")"
source "$D/scripts/openshell-auth.sh"
openshell_auth_init
set +e
openshell sandbox list 2>&1 | head -10
for n in $(openshell sandbox list 2>/dev/null | awk 'NR>1 && $1!="NAME"{print $1}'); do
  echo "deleting $n"; openshell sandbox delete "$n" 2>&1 | tail -1
done
set -e
trap 'kill "${OPENSHELL_TOKEN_REFRESHER_PID:-}" 2>/dev/null || true' EXIT

echo "===== rebuild + push runner image ====="
bash $HOST_DIR/rebuild-runner.sh 2>&1 | tail -3
bash $HOST_DIR/push-runner-image.sh 2>&1 | tail -3

echo "===== apply job ====="
oc -n fullsend delete job fullsend-triage --ignore-not-found >/dev/null
oc -n fullsend apply -f "$D/k8s/rendered/job-triage.yaml"

echo "===== watch ====="
for i in $(seq 1 220); do
  st=$(oc -n fullsend get pods -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo "[$i] ${st:-none}"
  case "$st" in Completed|Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull) break ;; esac
  sleep 20
done

echo "===== logs ====="
oc -n fullsend logs job/fullsend-triage --tail=160

echo "===== repo state ====="
set -a; source "$T/gh.env"; set +a
GH_TOKEN="$GH_TOKEN" gh issue view 1 --repo ${PROBE_REPO} --json state,labels --jq '{state, labels: [.labels[].name]}'
GH_TOKEN="$GH_TOKEN" gh pr list --repo ${PROBE_REPO} --state all --json number,title,headRefName,url --limit 10
GH_TOKEN="$GH_TOKEN" gh api repos/${PROBE_REPO}/branches --jq '.[].name'
echo PI_CODE3_DONE
