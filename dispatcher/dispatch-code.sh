#!/usr/bin/env bash
# SUPERSEDED by dispatch.sh (multi-project). Kept for reference only: this
# single-repo dispatcher has no fullsend/repo label and is not shipped in the
# fullsend-dispatcher ConfigMap any more.
# dispatch-code.sh — find code work and start a code Job per work item.
#
# Triggers:
#   * an open issue labelled `ready-to-code`
#   * an issue comment beginning with `/fs-code`
#
# Dedup / bookkeeping:
#   * an open PR with head `agent/<n>-*` means the work is already done
#   * `fullsend/code-running` on the issue means a Job is in flight
#   * a Job labelled `fullsend/issue=<n>` that is still running also blocks
#   * `/fs-code` comments are marked with an `eyes` reaction by this account,
#     so a comment is dispatched at most once
#   * on completion the reconciler replaces `fullsend/code-running` with
#     `fullsend/code-succeeded` / `fullsend/code-failed`
#
# DRY_RUN=1 logs decisions without mutating GitHub or Kubernetes.
set -uo pipefail

REPO="${FULLSEND_REPO:?FULLSEND_REPO must be set (owner/repo)}"
API="${GITHUB_API_URL:-https://api.github.com}"
NS="${FULLSEND_NAMESPACE:-fullsend}"
DRY_RUN="${DRY_RUN:-0}"
CODE_IMAGE="${FULLSEND_CODE_IMAGE:-image-registry.openshift-image-registry.svc:5000/fullsend/fullsend-runner-okd:dev}"
GW_URL="${OPENSHELL_GATEWAY_URL:?OPENSHELL_GATEWAY_URL must be set}"
SCRIPT_CM="${FULLSEND_SCRIPTS_CONFIGMAP:-fullsend-runner-scripts}"

# Identity: mint a GitHub App installation token for this run. Falls back to an
# injected GH_TOKEN when GITHUB_APP_ID is unset.
if [[ -n "${GITHUB_APP_ID:-}" ]]; then
  GH_TOKEN=$(bash /scripts/mint-app-token.sh \
    "$GITHUB_APP_ID" \
    "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID must be set with GITHUB_APP_ID}" \
    "${GITHUB_APP_PRIVATE_KEY:-/var/run/secrets/github-app/private-key}") \
    || { echo "[dispatch] app installation token mint failed" >&2; exit 1; }
  export GH_TOKEN
fi

AUTH=(-H "Authorization: Bearer ${GH_TOKEN:?GH_TOKEN must be set}" -H "Accept: application/vnd.github+json")
SA=/var/run/secrets/kubernetes.io/serviceaccount
K8S=https://kubernetes.default.svc
KCA="$SA/ca.crt"
KTOK=$(cat "$SA/token")

gh_get()  { curl -fsS "${AUTH[@]}" "$@"; }
gh_post() { curl -fsS -X POST "${AUTH[@]}" "$@"; }
gh_del()  { curl -sS -X DELETE "${AUTH[@]}" "$@" >/dev/null; }
k()       { curl -sS --cacert "$KCA" -H "Authorization: Bearer $KTOK" -H "Content-Type: application/json" "$@"; }

log() { echo "[dispatch] $*"; }

# Installation tokens cannot call REST GET /user; resolve the bot through
# GraphQL viewer and fall back to /user for PAT runs.
ME=$(curl -fsS -X POST "$API/graphql" "${AUTH[@]}" -H "Content-Type: application/json" \
       -d '{"query":"{viewer{login}}"}' 2>/dev/null | jq -r '.data.viewer.login // empty')
[[ -n "$ME" ]] || ME=$(gh_get "$API/user" 2>/dev/null | jq -r '.login // empty')
[[ -n "$ME" ]] || { echo "[dispatch] cannot resolve the authenticated identity" >&2; exit 1; }
log "repo=$REPO as=$ME dry_run=$DRY_RUN"

add_label()    { [[ "$DRY_RUN" == 1 ]] && { log "would add label $2 to #$1"; return; }
                 gh_post "$API/repos/$REPO/issues/$1/labels" -d "$(jq -n --arg l "$2" '{labels:[$l]}')" >/dev/null; }
remove_label() { [[ "$DRY_RUN" == 1 ]] && { log "would remove label $2 from #$1"; return; }
                 gh_del "$API/repos/$REPO/issues/$1/labels/$2"; }

open_pr_for() { # $1 number -> PR number or empty
  gh_get "$API/repos/$REPO/pulls?state=open&per_page=100" \
    | jq -r --arg n "$1" '.[] | select(.head.ref|startswith("agent/"+$n+"-")) | .number' | head -1
}

jobs_for() { # $1 number -> JSON array of jobs
  k "$K8S/apis/batch/v1/namespaces/$NS/jobs?labelSelector=$(printf 'fullsend/issue=%s' "$1" | jq -sRr @uri)" 2>/dev/null
}

job_state() { # $1 number -> running|succeeded|failed|none
  local js
  js=$(jobs_for "$1")
  [[ -z "$js" ]] && { echo none; return; }
  echo "$js" | jq -r '
    if ([.items[]? | select((.status.succeeded // 0) == 0 and (.status.failed // 0) == 0)] | length) > 0 then "running"
    elif ([.items[]? | select((.status.succeeded // 0) > 0)] | length) > 0 then "succeeded"
    elif ([.items[]? | select((.status.failed // 0) > 0)] | length) > 0 then "failed"
    else "none" end'
}

job_manifest() { # $1 number, $2 issue url, $3 comment body (optional)
  jq -n \
    --arg name "fullsend-code-$1" \
    --arg num "$1" \
    --arg url "$2" \
    --arg body "$3" \
    --arg img "$CODE_IMAGE" \
    --arg gw "$GW_URL" \
    --arg cm "$SCRIPT_CM" \
    --arg repo "$REPO" \
    '{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {
        generateName: ($name + "-"),
        namespace: "fullsend",
        labels: { app: "fullsend-agent", "fullsend/stage": "code", "fullsend/issue": $num }
      },
      spec: {
        backoffLimit: 0,
        activeDeadlineSeconds: 3300,
        ttlSecondsAfterFinished: 7200,
        template: {
          metadata: { labels: { app: "fullsend-agent", "fullsend/stage": "code", "fullsend/issue": $num } },
          spec: {
            restartPolicy: "Never",
            serviceAccountName: "fullsend-runner",
            containers: [{
              name: "agent",
              image: $img,
              imagePullPolicy: "Always",
              command: ["/bin/bash", "/scripts/run-agent.sh"],
              env: [
                { name: "FULLSEND_FORGE", value: "github" },
                { name: "GITHUB_APP_ID",
                  valueFrom: { secretKeyRef: { name: "fullsend-github-app", key: "app-id" } } },
                { name: "GITHUB_APP_INSTALLATION_ID",
                  valueFrom: { secretKeyRef: { name: "fullsend-github-app", key: "installation-id" } } },
                { name: "FULLSEND_ISSUE_URL", value: $url },
                { name: "FULLSEND_REPO_SLUG", value: $repo },
                { name: "FULLSEND_AGENT", value: "code" },
                { name: "FULLSEND_RUNTIME", value: "pi" },
                { name: "FULLSEND_MODEL", value: "gateway/qwen38" },
                { name: "FULLSEND_RUN_POST", value: "1" },
                { name: "COMMENT_BODY", value: $body },
                { name: "OPENSHELL_GATEWAY_URL", value: $gw },
                { name: "KEYCLOAK_CLIENT_SECRET", valueFrom: { secretKeyRef: { name: "fullsend-runner-keycloak", key: "client-secret" } } },
                { name: "FULLSEND_INFERENCE_GATEWAY_API_KEY", valueFrom: { secretKeyRef: { name: "litellm-inference-key", key: "api-key" } } }
              ],
              resources: {
                requests: { cpu: "500m", memory: "1Gi" },
                limits: { cpu: "2", memory: "3Gi" }
              },
              volumeMounts: [
                { name: "scripts", mountPath: "/scripts", readOnly: true },
                { name: "gateway-ca", mountPath: "/etc/openshell-ca", readOnly: true },
                { name: "github-app", mountPath: "/var/run/secrets/github-app", readOnly: true },
                { name: "output", mountPath: "/work/output" }
              ]
            }],
            volumes: [
              { name: "scripts", configMap: { name: $cm, defaultMode: 365 } },
              { name: "gateway-ca", configMap: { name: "fullsend-gateway-ca", items: [{ key: "ca.crt", path: "ca.crt" }] } },
              { name: "github-app", secret: { secretName: "fullsend-github-app", items: [{ key: "private-key", path: "private-key" }] } },
              { name: "output", persistentVolumeClaim: { claimName: "fullsend-output" } }
            ]
          }
        }
      }
    }'
}

dispatch() { # $1 number, $2 url, $3 body
  local num="$1" url="$2" body="${3:-}"
  local pr state
  pr=$(open_pr_for "$num")
  if [[ -n "$pr" ]]; then
    log "#$num already has open PR #$pr; removing ready-to-code"
    remove_label "$num" ready-to-code
    add_label "$num" fullsend/pr-open
    return
  fi
  state=$(job_state "$num")
  if [[ "$state" == "running" ]]; then
    log "#$num already has a running code job; skipping"
    return
  fi
  log "dispatching code for #$num ($url) body='${body:0:80}'"
  if [[ "$DRY_RUN" == 1 ]]; then return; fi
  add_label "$num" fullsend/code-running
  remove_label "$num" ready-to-code
  local out
  out=$(k -X POST "$K8S/apis/batch/v1/namespaces/$NS/jobs" -d "$(job_manifest "$num" "$url" "$body")")
  if echo "$out" | jq -e '.metadata.name' >/dev/null 2>&1; then
    log "#$num job created: $(echo "$out" | jq -r .metadata.name)"
  else
    log "ERROR creating job for #$num: $out"
    remove_label "$num" fullsend/code-running
  fi
}

# ---------------------------------------------------------------- reconcile --
for num in $(gh_get "$API/repos/$REPO/issues?state=open&labels=fullsend/code-running&per_page=100" | jq -r '.[].number'); do
  state=$(job_state "$num")
  if [[ "$state" == "running" ]]; then
    log "#$num code job still running"
    continue
  fi
  log "#$num code job state=$state; clearing code-running"
  remove_label "$num" fullsend/code-running
  [[ "$state" == "succeeded" ]] && add_label "$num" fullsend/code-succeeded
  [[ "$state" == "failed" ]]    && add_label "$num" fullsend/code-failed
done

# ------------------------------------------------------------ label trigger --
for row in $(gh_get "$API/repos/$REPO/issues?state=open&labels=ready-to-code&per_page=100" \
  | jq -r '.[] | select(.pull_request == null) | "\(.number)|\(.html_url)"'); do
  dispatch "${row%%|*}" "${row#*|}" ""
done

# ----------------------------------------------------------- comment trigger --
for row in $(gh_get "$API/repos/$REPO/issues/comments?per_page=100&sort=created&direction=desc" \
  | jq -r '.[] | select(.body|test("^/fs-code(\\s|$)")) | "\(.id)|\(.issue_url)|\(.body|@base64)"'); do
  cid="${row%%|*}"; rest="${row#*|}"; issue_url="${rest%%|*}"; b64="${rest#*|}"
  body=$(printf '%s' "$b64" | base64 -d)
  num="${issue_url##*/}"
  seen=$(gh_get "$API/repos/$REPO/issues/comments/$cid/reactions" 2>/dev/null \
    | jq -r --arg me "$ME" '[.[]? | select(.user.login==$me and .content=="eyes")] | length')
  if [[ "${seen:-0}" -gt 0 ]]; then
    log "comment $cid already dispatched"
    continue
  fi
  instruction=$(printf '%s' "$body" | sed -E 's|^/fs-code[[:space:]]*||')
  dispatch "$num" "https://github.com/$REPO/issues/$num" "$instruction"
  if [[ "$DRY_RUN" != 1 ]]; then
    gh_post "$API/repos/$REPO/issues/comments/$cid/reactions" -d '{"content":"eyes"}' >/dev/null || true
  fi
done

log "done"
