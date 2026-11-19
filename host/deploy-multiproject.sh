#!/usr/bin/env bash
# deploy-multiproject.sh — deploy the registry-driven dispatcher (B1).
#
#   1. refresh the dispatcher ConfigMap (dispatch.sh + mint helper)
#   2. apply the project registry and scan-state ConfigMaps
#   3. apply the split CronJobs, remove the superseded fullsend-dispatch one
#   4. smoke: run reconcile and scan once, show logs and the resulting state
#
# Requires a live `oc login`. Logs to $SECRETS_DIR/deploy-multiproject.log.
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

LOG=$T/deploy-multiproject.log
: > "$LOG"; exec >> "$LOG" 2>&1

[[ -f "$D/k8s/projects-config.yaml" ]] || { echo "missing $D/k8s/projects-config.yaml — copy k8s/projects-config.example.yaml" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "not logged in: run 'oc login' first"; exit 1; }

echo "===== 0. validate ====="
REG=$(sed -n '/projects.json: |/,/^---/p' "$D/k8s/projects-config.yaml" | sed '1d;/^---/d;s/^    //')
jq -e 'type=="array" and length>0' <<<"$REG" >/dev/null || { echo "projects.json invalid"; exit 1; }
echo "projects: $(jq -r '[.[]|.key]|join(",")' <<<"$REG")"
bash -n "$D/dispatcher/dispatch.sh" || exit 1

echo "===== 1. dispatcher configmap ====="
oc -n "$NS" create configmap fullsend-dispatcher \
  --from-file=dispatch.sh="$D/dispatcher/dispatch.sh" \
  --from-file=mint-app-token.sh="$D/scripts/mint-app-token.sh" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -
# The superseded single-repo dispatcher must not linger in the ConfigMap.
oc -n "$NS" patch configmap fullsend-dispatcher --type=json \
  -p '[{"op":"remove","path":"/data/dispatch-code.sh"}]' >/dev/null 2>&1 || true
oc -n "$NS" get cm fullsend-dispatcher -o json | jq -r '.data|keys|"  keys: " + join(",")'

echo "===== 2. registry + state ====="
oc -n "$NS" apply -f "$D/k8s/projects-config.yaml"
oc -n "$NS" get cm fullsend-dispatch-state -o jsonpath='{.data}'; echo

echo "===== 3. cronjobs ====="
"$D/host/render-manifests.sh" >/dev/null
oc -n "$NS" apply -f "$D/k8s/rendered/dispatcher.yaml"
oc -n "$NS" delete cronjob fullsend-dispatch --ignore-not-found 2>&1 | tail -1
oc -n "$NS" get cronjob --no-headers | awk '{print "  " $1, $2, $3}'

echo "===== 4a. reconcile once ====="
oc -n "$NS" delete job mp-reconcile --ignore-not-found >/dev/null
oc -n "$NS" create job mp-reconcile --from=cronjob/fullsend-reconcile >/dev/null
for _ in $(seq 1 30); do
  st=$(oc -n "$NS" get pods -l job-name=mp-reconcile --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac; sleep 4
done
oc -n "$NS" logs job/mp-reconcile 2>&1 | tail -20

echo "===== 4b. scan once ====="
oc -n "$NS" delete job mp-scan --ignore-not-found >/dev/null
oc -n "$NS" create job mp-scan --from=cronjob/fullsend-scan >/dev/null
for _ in $(seq 1 40); do
  st=$(oc -n "$NS" get pods -l job-name=mp-scan --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac; sleep 4
done
oc -n "$NS" logs job/mp-scan 2>&1 | tail -30

echo "===== 5. state after scan ====="
oc -n "$NS" get cm fullsend-dispatch-state -o jsonpath='{.data}'; echo
oc -n "$NS" get jobs -l app=fullsend-agent --no-headers 2>/dev/null | awk '{print "  " $1}' | tail -5
echo "done"
