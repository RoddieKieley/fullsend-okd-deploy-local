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
LOG="$T/dispatcher-deploy2.log"
: > "$LOG"
exec >> "$LOG" 2>&1

set -a; source "$T/gh.env"; set +a
R=${PROBE_REPO}

echo "===== 1. configmap ====="
oc -n "$NS" create configmap fullsend-dispatcher \
  --from-file=dispatch.sh="$D/dispatcher/dispatch.sh" \
  --from-file=mint-app-token.sh="$D/scripts/mint-app-token.sh" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -

echo "===== 2. cronjob ====="
"$D/host/render-manifests.sh" >/dev/null
oc -n "$NS" apply -f "$D/k8s/rendered/dispatcher.yaml"

echo "===== 3. labels ====="
existing=$(GH_TOKEN="$GH_TOKEN" gh label list --repo "$R" --limit 300 --json name --jq '.[].name')
create() {
  local name="$1" color="$2" desc="$3"
  if grep -qxF "$name" <<<"$existing"; then return; fi
  GH_TOKEN="$GH_TOKEN" gh label create "$name" --repo "$R" --color "$color" --description "$desc" 2>&1 | tail -1
}
create "ready-for-triage"         "0e8a16" "Queued for the fullsend triage agent"
create "fullsend/triage-running"  "fbca04" "A triage job is in flight"
create "fullsend/triage-succeeded" "0e8a16" "The triage job completed"
create "fullsend/triage-failed"   "d93f0b" "The triage job failed"
# standard triage post-script control labels, in case an outcome needs one
create "bug"             "d73a4a" "Something is not working"
create "documentation"   "0075ca" "Documentation only"
create "duplicate"       "cfd3d7" "Duplicate of another issue"
create "question"        "d876e3" "Further information is requested"
create "not-planned"     "ffffff" "Will not be worked on"
create "completed"       "0e8a16" "Already completed"
create "blocked"         "d93f0b" "Blocked on prerequisites"
create "pr-open"         "1d76db" "An open pull request covers this issue"

echo "===== 4. test issue ====="
NUM=$(GH_TOKEN="$GH_TOKEN" gh issue list --repo "$R" --state open --search 'in:title "triage track test"' --json number,title --jq '.[0].number // empty')
if [[ -z "$NUM" ]]; then
  URL=$(GH_TOKEN="$GH_TOKEN" gh issue create --repo "$R" \
    --title "Documentation: README does not explain how to run the program" \
    --body "The README has no usage section. A new user cannot tell how to build or run the program." 2>&1 | tail -1)
  NUM="${URL##*/}"
  echo "created issue #$NUM ($URL)"
fi
[[ -z "$NUM" ]] && NUM=$(GH_TOKEN="$GH_TOKEN" gh issue list --repo "$R" --state open --search 'in:title README does not explain' --json number --jq '.[0].number')
echo "test issue: #$NUM"
GH_TOKEN="$GH_TOKEN" gh issue edit "$NUM" --repo "$R" --add-label ready-for-triage 2>&1 | tail -1

echo "===== 5. dry run ====="
oc -n "$NS" delete job dispatcher-dryrun --ignore-not-found >/dev/null
oc -n "$NS" apply -f "$D/k8s/rendered/dispatcher-dryrun.yaml" >/dev/null
for i in $(seq 1 30); do
  st=$(oc -n "$NS" get pods -l job-name=dispatcher-dryrun --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 4
done
oc -n "$NS" logs job/dispatcher-dryrun 2>&1

echo "===== 6. real run ====="
oc -n "$NS" delete job dispatcher-once --ignore-not-found >/dev/null
oc -n "$NS" create job dispatcher-once --from=cronjob/fullsend-dispatch >/dev/null
for i in $(seq 1 30); do
  st=$(oc -n "$NS" get pods -l job-name=dispatcher-once --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 4
done
oc -n "$NS" logs job/dispatcher-once 2>&1

echo "===== 7. jobs / labels ====="
oc -n "$NS" get jobs -l fullsend/stage=triage -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp' | tail -3
GH_TOKEN="$GH_TOKEN" gh issue view "$NUM" --repo "$R" --json labels --jq '[.labels[].name]'
echo "TEST_ISSUE=$NUM"
