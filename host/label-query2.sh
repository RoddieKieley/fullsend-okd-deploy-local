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
set -a; source "$T/gh.env"; set +a
echo "== host query ready-to-code =="
curl -sS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${PROBE_REPO}/issues?state=open&labels=ready-to-code&per_page=100" \
  | jq -r '.[] | "\(.number) \(.title) pr=\(.pull_request // "none")"'
echo "== dispatcher dry run again =="
oc -n fullsend delete job dispatcher-dryrun --ignore-not-found >/dev/null
oc -n fullsend apply -f $OKD_ROOT/k8s/rendered/dispatcher-dryrun.yaml >/dev/null
for i in $(seq 1 30); do
  st=$(oc -n fullsend get pods -l job-name=dispatcher-dryrun --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 4
done
oc -n fullsend logs job/dispatcher-dryrun 2>&1
