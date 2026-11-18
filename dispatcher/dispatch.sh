#!/usr/bin/env bash
# dispatch.sh — multi-project dispatcher.
#
#   dispatch.sh reconcile   cheap pass: fullsend/<stage>-running -> -succeeded|-failed
#   dispatch.sh scan        discovery: new issues, ready-for-*, /fs-* comments
#
# Projects come from ConfigMap $FULLSEND_PROJECTS_CONFIGMAP, data key
# projects.json (a JSON array). Per-project fields:
#
#   key              short id used in Job labels/names (no '/')
#   repo             owner/name
#   enabled          bool, default true
#   installation_id  GitHub App installation (default: GITHUB_APP_INSTALLATION_ID)
#   poll_seconds     scan cadence for this project (default 600)
#   deadline_seconds code Job activeDeadlineSeconds (default 3300, max 3300)
#   triage_deadline_seconds triage Job deadline (default 2400)
#   max_code         per-project concurrent code Jobs (default 2)
#   max_triage       per-project concurrent triage Jobs (default 2)
#   triage_max_age_days  discovery window (default 30)
#   model_code / model_triage / image
#   code_order       ready-to-code scan order: newest (default) | oldest
#
# Per-model concurrency is capped by models.json in the same ConfigMap, keyed by
# the model id used in model_code/model_triage:
#
#   { "gateway/qwen38": { "max_concurrent": 2 } }
#
# Jobs carry fullsend/model=<slug> (the id with '/' and other label-illegal
# characters replaced by '-'), so the count is stage-agnostic: a model shared by
# triage and code is counted once. A scan refuses to start if a project
# references a model with no models.json entry.
#
# Scan gating state lives in ConfigMap $FULLSEND_STATE_CONFIGMAP as
# data.<key> = <unix epoch of last completed scan>. Reconcile ignores it: it is
# cheap and runs on a faster CronJob so stage transitions are not delayed by a
# project's poll interval.
#
# Every Job is labelled fullsend/repo=<key> in addition to stage+issue, so issue
# numbers cannot collide across projects.
set -uo pipefail

MODE=${1:-${FULLSEND_MODE:-scan}}
case "$MODE" in scan|reconcile) ;; *) echo "usage: dispatch.sh [scan|reconcile]" >&2; exit 2 ;; esac

API="${GITHUB_API_URL:-https://api.github.com}"
NS="${FULLSEND_NAMESPACE:-fullsend}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_SCAN="${FORCE_SCAN:-0}"
AGENT_IMAGE="${FULLSEND_AGENT_IMAGE:-image-registry.openshift-image-registry.svc:5000/fullsend/fullsend-runner-okd:dev}"
GW_URL="${OPENSHELL_GATEWAY_URL:?OPENSHELL_GATEWAY_URL must be set}"
SCRIPT_CM="${FULLSEND_SCRIPTS_CONFIGMAP:-fullsend-runner-scripts}"
PROJECTS_CM="${FULLSEND_PROJECTS_CONFIGMAP:-fullsend-projects}"
STATE_CM="${FULLSEND_STATE_CONFIGMAP:-fullsend-dispatch-state}"
GLOBAL_MAX_CODE="${FULLSEND_MAX_CONCURRENT_CODE:-4}"
GLOBAL_MAX_TRIAGE="${FULLSEND_MAX_CONCURRENT_TRIAGE:-4}"
APP_ID="${GITHUB_APP_ID:-}"
APP_KEY="${GITHUB_APP_PRIVATE_KEY:-/var/run/secrets/github-app/private-key}"
DEFAULT_INSTALLATION="${GITHUB_APP_INSTALLATION_ID:-}"
TRIAGE_MARKER="<!-- fullsend:triage-agent -->"

SA=/var/run/secrets/kubernetes.io/serviceaccount
K8S=https://kubernetes.default.svc
KCA="$SA/ca.crt"
KTOK=$(cat "$SA/token")

k() { curl -sS --cacert "$KCA" -H "Authorization: Bearer $KTOK" -H "Content-Type: application/json" "$@"; }
# Merge-patch needs exactly one Content-Type. k() sets application/json, so a
# second -H would send two headers and the API rejects the request silently
# under -sS; use this helper and let -f surface failures.
kpatch() { curl -sS -f --cacert "$KCA" -H "Authorization: Bearer $KTOK" \
             -H "Content-Type: application/merge-patch+json" -X PATCH "$@"; }
log() { echo "[dispatch:$MODE] $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

declare -A TOKENS=()

# ---------------------------------------------------------------- identity --
token_for() { # $1 installation id -> installation token on stdout
  local inst=$1
  [[ -n ${TOKENS[$inst]:-} ]] && { printf '%s' "${TOKENS[$inst]}"; return 0; }
  local t
  if [[ -n "$APP_ID" ]]; then
    t=$(bash /scripts/mint-app-token.sh "$APP_ID" "$inst" "$APP_KEY") || return 1
  else
    t="${GH_TOKEN:-}"
    [[ -n "$t" ]] || { log "no GITHUB_APP_ID and no GH_TOKEN"; return 1; }
  fi
  TOKENS[$inst]=$t
  printf '%s' "$t"
}

api()      { local tok=$1; shift; curl -fsS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" "$@"; }
api_post() { local tok=$1; shift; curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" "$@"; }
api_del()  { local tok=$1; shift; curl -sS -X DELETE -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" "$@" >/dev/null; }
api_patch(){ local tok=$1; shift; curl -sS -X PATCH -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" "$@"; }

# ------------------------------------------------------------------ github --
label_add()    { local tok=$1 repo=$2 num=$3 l=$4
                 [[ "$DRY_RUN" == 1 ]] && { log "would add label $l to $repo#$num"; return 0; }
                 api_post "$tok" "$API/repos/$repo/issues/$num/labels" \
                   -d "$(jq -n --arg l "$l" '{labels:[$l]}')" >/dev/null; }
label_remove() { local tok=$1 repo=$2 num=$3 l=$4
                 [[ "$DRY_RUN" == 1 ]] && { log "would remove label $l from $repo#$num"; return 0; }
                 api_del "$tok" "$API/repos/$repo/issues/$num/labels/${l//\//%2F}"; }

open_pr_for() { # $1 tok, $2 repo, $3 number -> PR number or empty
  api "$1" "$API/repos/$2/pulls?state=open&per_page=100" \
    | jq -r --arg n "$3" '.[] | select(.head.ref|startswith("agent/"+$n+"-")) | .number' | head -1
}

triage_marked() { # $1 tok, $2 repo, $3 number -> true when a triage-agent comment exists
  api "$1" "$API/repos/$2/issues/$3/comments?per_page=100" 2>/dev/null \
    | jq -e --arg m "$TRIAGE_MARKER" 'any(.body? // "" | contains($m))' >/dev/null 2>&1
}

# force_requested <body> — true when the trigger is `/fs-code --force`.
# Mirrors the pre-script: only the second token of the first line counts, so a
# comment merely mentioning --force cannot bypass the tracking-issue check.
force_requested() {
  local first second
  [[ -n "${1:-}" ]] || return 1
  first=${1%%$'\n'*}
  second=$(printf '%s' "$first" | tr -d '\r' | awk '{print $2}')
  [[ "$second" == "--force" ]]
}

# sub_issue_count <tok> <repo> <number> — GitHub native sub-issues (children).
# A tracking/parent issue implements nothing itself: the code agent works the
# leaves, so the dispatcher must not spend a Job on the parent.
sub_issue_count() {
  local tok=$1 repo=$2 num=$3 owner name n
  owner=${repo%%/*}; name=${repo##*/}
  n=$(api "$tok" "$API/graphql" -H "Content-Type: application/json" \
        -d "$(jq -n --arg o "$owner" --arg n "$name" --argjson i "$num" \
              '{query:"query($o:String!,$n:String!,$i:Int!){repository(owner:$o,name:$n){issue(number:$i){subIssuesSummary{total}}}}",
                variables:{o:$o,n:$n,i:$i}}')" \
        2>/dev/null | jq -r '.data.repository.issue.subIssuesSummary.total // 0' 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# ------------------------------------------------------------------ k8s ------
jobs_for() { # $1 key, $2 stage, [$3 number] -> JSON
  local sel="fullsend/stage=$2,fullsend/repo=$1"
  [[ -n "${3:-}" ]] && sel+=",fullsend/issue=$3"
  k "$K8S/apis/batch/v1/namespaces/$NS/jobs?labelSelector=$(printf '%s' "$sel" | jq -sRr @uri)" 2>/dev/null
}

job_state() { # $1 key, $2 stage, $3 number -> running|succeeded|failed|none
  local js
  js=$(jobs_for "$1" "$2" "$3")
  [[ -z "$js" ]] && { echo none; return; }
  echo "$js" | jq -r '
    if ([.items[]? | select((.status.succeeded // 0) == 0 and (.status.failed // 0) == 0)] | length) > 0 then "running"
    elif ([.items[]? | select((.status.succeeded // 0) > 0)] | length) > 0 then "succeeded"
    elif ([.items[]? | select((.status.failed // 0) > 0)] | length) > 0 then "failed"
    else "none" end'
}

running_count() { # $1 key, $2 stage -> in-flight jobs for that project
  local c
  c=$(jobs_for "$1" "$2" | jq -r '[.items[]? | select((.status.succeeded // 0) == 0 and (.status.failed // 0) == 0)] | length' 2>/dev/null)
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  echo "$c"
}

# model_slug <model id> -> Kubernetes label value (alnum, '-', '_', '.')
model_slug() {
  printf '%s' "$1" \
    | sed -e 's/[^A-Za-z0-9._-]/-/g' \
    | sed -e 's/^[^A-Za-z0-9]*//' -e 's/[^A-Za-z0-9]*$//' \
    | cut -c1-63
}

model_cap() { # $1 model id -> max_concurrent or empty
  jq -r --arg m "$1" '.[$m].max_concurrent // empty' "$TMP/models.json" 2>/dev/null
}

model_locality() { # $1 model id -> local | remote | empty
  jq -r --arg m "$1" '.[$m].locality // empty' "$TMP/models.json" 2>/dev/null
}

# code_order_direction <project json> — scan order for ready-to-code issues.
#   oldest -> sort=created&direction=asc   (FIFO-ish by issue creation)
#   newest -> sort=created&direction=desc  (default; GitHub's own default)
code_order_direction() {
  local order
  order=$(jq -r '.code_order // "newest"' <<<"$1")
  [[ "$order" == "oldest" ]] && printf 'asc' || printf 'desc'
}

running_for_model() { # $1 model id -> in-flight jobs using that model
  # Counted by label (current jobs) OR by the FULLSEND_MODEL env entry, so jobs
  # created before the fullsend/model label existed still occupy the model pool
  # until they finish.
  local slug c
  slug=$(model_slug "$1")
  c=$(k "$K8S/apis/batch/v1/namespaces/$NS/jobs" 2>/dev/null | jq -r --arg slug "$slug" --arg model "$1" '
      [ .items[]
        | select((.status.succeeded // 0) == 0 and (.status.failed // 0) == 0)
        | select(
            (.metadata.labels["fullsend/model"] // "") == $slug
            or ([.spec.template.spec.containers[0].env[]?
                 | select(.name == "FULLSEND_MODEL") | .value][0] // "") == $model
          )
      ] | length' 2>/dev/null)
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  echo "$c"
}

# model_available <model id> -> 0 when under cap (or uncapped)
model_available() {
  local model=$1 cap inuse
  cap=$(model_cap "$model")
  [[ -z "$cap" ]] && return 0
  inuse=$(running_for_model "$(model_slug "$model")")
  if [[ "$inuse" -ge "$cap" ]]; then
    log "model $model at cap ($inuse/$cap); deferring"
    return 1
  fi
  return 0
}

# validate_registry — fail the scan, closed, on an unsafe or incomplete registry:
#   * every model a project references must have a max_concurrent cap and a
#     locality (local|remote), so a new model cannot be added silently
#   * a project with privacy=local may only reference locality=local models
# Nothing is dispatched when validation fails.
validate_registry() {
  local errors="" model privacy locality key mcode mtriage
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    [[ -n "$(model_cap "$model")" ]] || errors+="${errors:+; }$model has no max_concurrent in models.json"
    [[ -n "$(model_locality "$model")" ]] || errors+="${errors:+; }$model has no locality in models.json"
  done < <(jq -r '.[] | select(.enabled // true)
                  | (.model_code // "gateway/qwen38"), (.model_triage // "ollama/Qwen3.8-27B")' \
             "$TMP/projects.json" | sort -u)

  while IFS=$'\t' read -r key privacy mcode mtriage; do
    [[ "$privacy" == "local" ]] || continue
    for model in "$mcode" "$mtriage"; do
      locality=$(model_locality "$model")
      [[ "$locality" == "local" ]] || errors+="${errors:+; }$key is privacy=local but uses $model (locality=${locality:-unknown})"
    done
  done < <(jq -r '.[] | select(.enabled // true)
                  | [.key, (.privacy // "any"),
                     (.model_code // "gateway/qwen38"),
                     (.model_triage // "ollama/Qwen3.8-27B")] | @tsv' "$TMP/projects.json")

  [[ -z "$errors" ]] && return 0
  log "ERROR: registry rejected: $errors"
  return 1
}

global_running() { # $1 stage -> in-flight jobs across every project
  local c
  c=$(k "$K8S/apis/batch/v1/namespaces/$NS/jobs?labelSelector=$(printf 'fullsend/stage=%s' "$1" | jq -sRr @uri)" 2>/dev/null \
    | jq -r '[.items[]? | select((.status.succeeded // 0) == 0 and (.status.failed // 0) == 0)] | length' 2>/dev/null)
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  echo "$c"
}

# ------------------------------------------------------------------ state ----
state_get() { # $1 key -> epoch or empty
  k "$K8S/api/v1/namespaces/$NS/configmaps/$STATE_CM" 2>/dev/null \
    | jq -r --arg k "$1" '.data[$k] // empty'
}

state_set() { # $1 key, $2 epoch
  [[ "$DRY_RUN" == 1 ]] && return 0
  local err
  err=$(kpatch "$K8S/api/v1/namespaces/$NS/configmaps/$STATE_CM" \
        -d "$(jq -n --arg k "$1" --arg v "$2" '{data:{($k):$v}}')" 2>&1) \
    || log "WARNING: could not persist scan state for $1: $err"
}

# ------------------------------------------------------------------ jobs -----
job_manifest() { # $1 json, $2 stage, $3 number, $4 url, $5 body
  local pj=$1 stage=$2 num=$3 url=$4 body=$5
  local key repo model deadline image agent runtime mslug locality
  key=$(jq -r .key <<<"$pj")
  repo=$(jq -r .repo <<<"$pj")
  image=$(jq -r --arg d "$AGENT_IMAGE" '.image // $d' <<<"$pj")
  if [[ $stage == code ]]; then
    agent=code; runtime=pi
    model=$(jq -r --arg d "gateway/qwen38" '.model_code // $d' <<<"$pj")
    deadline=$(jq -r --argjson d 3300 '.deadline_seconds // $d | if . > 3300 then 3300 else . end' <<<"$pj")
  else
    agent=triage; runtime=opencode
    model=$(jq -r --arg d "ollama/Qwen3.8-27B" '.model_triage // $d' <<<"$pj")
    deadline=$(jq -r --argjson d 2400 '.triage_deadline_seconds // $d' <<<"$pj")
  fi
  mslug=$(model_slug "$model")
  locality=$(model_locality "$model"); locality=${locality:-unknown}
  jq -n \
    --arg name "fullsend-$stage-$key" --arg num "$num" --arg url "$url" --arg body "$body" \
    --arg stage "$stage" --arg key "$key" --arg agent "$agent" --arg runtime "$runtime" \
    --arg model "$model" --arg mslug "$mslug" --arg locality "$locality" --arg img "$image" --arg gw "$GW_URL" --arg cm "$SCRIPT_CM" \
    --arg repo "$repo" --argjson deadline "$deadline" \
    '{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {
        generateName: ($name + "-"),
        namespace: "fullsend",
        labels: { app: "fullsend-agent", "fullsend/stage": $stage,
                  "fullsend/issue": $num, "fullsend/repo": $key,
                  "fullsend/model": $mslug, "fullsend/locality": $locality }
      },
      spec: {
        backoffLimit: 0,
        activeDeadlineSeconds: $deadline,
        ttlSecondsAfterFinished: 7200,
        template: {
          metadata: { labels: { app: "fullsend-agent", "fullsend/stage": $stage,
                                "fullsend/issue": $num, "fullsend/repo": $key,
                                "fullsend/model": $mslug, "fullsend/locality": $locality } },
          spec: {
            restartPolicy: "Never",
            serviceAccountName: "fullsend-runner",
            containers: [{
              name: "agent",
              image: $img,
              imagePullPolicy: "Always",
              command: ["/bin/bash", "/scripts/run-agent.sh"],
              env: ([
                { name: "FULLSEND_FORGE", value: "github" },
                { name: "GITHUB_APP_ID",
                  valueFrom: { secretKeyRef: { name: "fullsend-github-app", key: "app-id" } } },
                { name: "GITHUB_APP_INSTALLATION_ID",
                  valueFrom: { secretKeyRef: { name: "fullsend-github-app", key: "installation-id" } } },
                { name: "FULLSEND_ISSUE_URL", value: $url },
                { name: "FULLSEND_REPO_SLUG", value: $repo },
                { name: "FULLSEND_REPO_KEY", value: $key },
                { name: "FULLSEND_AGENT", value: $agent },
                { name: "FULLSEND_RUNTIME", value: $runtime },
                { name: "FULLSEND_MODEL", value: $model },
                { name: "FULLSEND_MODEL_LOCALITY", value: $locality },
                { name: "FULLSEND_RUN_POST", value: "1" },
                { name: "COMMENT_BODY", value: $body },
                { name: "OPENSHELL_GATEWAY_URL", value: $gw },
                { name: "KEYCLOAK_CLIENT_SECRET", valueFrom: { secretKeyRef: { name: "fullsend-runner-keycloak", key: "client-secret" } } }
              ] + (if $stage == "code"
                    then [{ name: "FULLSEND_INFERENCE_GATEWAY_API_KEY",
                            valueFrom: { secretKeyRef: { name: "litellm-inference-key", key: "api-key" } } }]
                    else [] end)),
              resources: { requests: { cpu: "500m", memory: "1Gi" }, limits: { cpu: "2", memory: "3Gi" } },
              volumeMounts: [
                { name: "scripts", mountPath: "/scripts", readOnly: true },
                { name: "gateway-ca", mountPath: "/etc/openshell-ca", readOnly: true },
                { name: "github-app", mountPath: "/var/run/secrets/github-app", readOnly: true }
              ]
            }],
            volumes: [
              { name: "scripts", configMap: { name: $cm, defaultMode: 365 } },
              { name: "gateway-ca", configMap: { name: "fullsend-gateway-ca", items: [{ key: "ca.crt", path: "ca.crt" }] } },
              { name: "github-app", secret: { secretName: "fullsend-github-app", items: [{ key: "private-key", path: "private-key" }] } }
            ]
          }
        }
      }
    }'
}

create_job() { # $1 json, $2 stage, $3 number, $4 url, $5 body
  local out
  if [[ "$DRY_RUN" == 1 ]]; then
    log "would create $2 job for $(jq -r .key <<<"$1")#$3"
    return 0
  fi
  out=$(k -X POST "$K8S/apis/batch/v1/namespaces/$NS/jobs" -d "$(job_manifest "$1" "$2" "$3" "$4" "$5")")
  if echo "$out" | jq -e '.metadata.name' >/dev/null 2>&1; then
    log "$(jq -r .key <<<"$1")#$3 $2 job created: $(echo "$out" | jq -r .metadata.name)"
    return 0
  fi
  log "ERROR creating $2 job for $(jq -r .key <<<"$1")#$3: $out"
  return 1
}

# -------------------------------------------------------------- reconcile ----
reconcile_project() { # $1 json, $2 token
  local pj=$1 tok=$2 key repo stage num state
  key=$(jq -r .key <<<"$pj"); repo=$(jq -r .repo <<<"$pj")
  for stage in triage code; do
    for num in $(api "$tok" "$API/repos/$repo/issues?state=all&labels=fullsend/$stage-running&per_page=100" | jq -r '.[].number'); do
      state=$(job_state "$key" "$stage" "$num")
      if [[ "$state" == running ]]; then log "$key#$num $stage still running"; continue; fi
      log "$key#$num $stage state=$state; clearing $stage-running"
      label_remove "$tok" "$repo" "$num" "fullsend/$stage-running"
      [[ "$state" == succeeded ]] && label_add "$tok" "$repo" "$num" "fullsend/$stage-succeeded"
      [[ "$state" == failed ]] && label_add "$tok" "$repo" "$num" "fullsend/$stage-failed"
    done
  done
}

# ------------------------------------------------------------------- scan ----
declare -A SEEN=()

dispatch_triage() { # $1 json, $2 token, $3 number, $4 url, $5 force
  local pj=$1 tok=$2 num=$3 url=$4 force=${5:-0} key repo
  key=$(jq -r .key <<<"$pj"); repo=$(jq -r .repo <<<"$pj")
  [[ -n "${SEEN[triage:$key:$num]:-}" ]] && { log "$key#$num triage already handled this run"; return; }
  SEEN[triage:$key:$num]=1
  local labels
  labels=$(api "$tok" "$API/repos/$repo/issues/$num" | jq -r '.labels[].name')
  grep -qxF fullsend/triage-running <<<"$labels" && { log "$key#$num triage already running (label)"; return; }
  [[ "$(job_state "$key" triage "$num")" == running ]] && { log "$key#$num triage job already running"; return; }
  if [[ "$force" != 1 ]] && triage_marked "$tok" "$repo" "$num"; then log "$key#$num already has a triage comment"; return; fi
  grep -qxF fullsend/code-running <<<"$labels" && { log "$key#$num is in code; skipping triage"; return; }
  local maxproj; maxproj=$(jq -r '.max_triage // 2' <<<"$pj")
  [[ "$(running_count "$key" triage)" -ge "$maxproj" ]] && { log "$key triage cap ($maxproj) reached"; return; }
  local tmodel; tmodel=$(jq -r --arg d "ollama/Qwen3.8-27B" '.model_triage // $d' <<<"$pj")
  model_available "$tmodel" || return 0
  [[ "$(global_running triage)" -ge "$GLOBAL_MAX_TRIAGE" ]] && { log "global triage cap ($GLOBAL_MAX_TRIAGE) reached"; return; }
  log "dispatching triage for $key#$num ($url)"
  [[ "$DRY_RUN" == 1 ]] && { create_job "$pj" triage "$num" "$url" ""; return; }
  # Job first, then the running label: the reconcile loop runs every 2 min and
  # must never observe fullsend/triage-running without a Job behind it.
  create_job "$pj" triage "$num" "$url" "" || return 0
  label_add "$tok" "$repo" "$num" fullsend/triage-running
  label_remove "$tok" "$repo" "$num" ready-for-triage
}

dispatch_code() { # $1 json, $2 token, $3 number, $4 url, $5 body
  local pj=$1 tok=$2 num=$3 url=$4 body=${5:-} key repo pr state
  key=$(jq -r .key <<<"$pj"); repo=$(jq -r .repo <<<"$pj")
  [[ -n "${SEEN[code:$key:$num]:-}" ]] && { log "$key#$num code already handled this run"; return; }
  SEEN[code:$key:$num]=1
  pr=$(open_pr_for "$tok" "$repo" "$num")
  if [[ -n "$pr" ]]; then
    log "$key#$num already has open PR #$pr; removing ready-to-code"
    label_remove "$tok" "$repo" "$num" ready-to-code
    label_add "$tok" "$repo" "$num" fullsend/pr-open
    return
  fi
  state=$(job_state "$key" code "$num")
  [[ "$state" == running ]] && { log "$key#$num already has a running code job"; return; }

  # Tracking/parent issues implement nothing: the code agent works the leaves.
  # /fs-code --force is the documented human override.
  if force_requested "${body:-}"; then
    log "$key#$num /fs-code --force: bypassing the tracking-issue check"
  else
    local subs
    subs=$(sub_issue_count "$tok" "$repo" "$num")
    if [[ "$subs" -gt 0 ]]; then
      log "$key#$num is a tracking issue ($subs sub-issues); skipping code"
      if [[ "$DRY_RUN" != 1 ]]; then
        label_remove "$tok" "$repo" "$num" ready-to-code
        label_add "$tok" "$repo" "$num" fullsend/tracking
      fi
      return 0
    fi
  fi

  local maxproj; maxproj=$(jq -r '.max_code // 2' <<<"$pj")
  [[ "$(running_count "$key" code)" -ge "$maxproj" ]] && { log "$key code cap ($maxproj) reached"; return; }
  local cmodel; cmodel=$(jq -r --arg d "gateway/qwen38" '.model_code // $d' <<<"$pj")
  model_available "$cmodel" || return 0
  [[ "$(global_running code)" -ge "$GLOBAL_MAX_CODE" ]] && { log "global code cap ($GLOBAL_MAX_CODE) reached"; return; }
  log "dispatching code for $key#$num ($url) body='${body:0:80}'"
  [[ "$DRY_RUN" == 1 ]] && { create_job "$pj" code "$num" "$url" "$body"; return; }
  # Job first, then the label — same reconcile-race rule as triage.
  create_job "$pj" code "$num" "$url" "$body" || return 0
  label_add "$tok" "$repo" "$num" fullsend/code-running
  label_remove "$tok" "$repo" "$num" ready-to-code
}

scan_project() { # $1 json, $2 token
  local pj=$1 tok=$2 key repo now last poll days max_age
  key=$(jq -r .key <<<"$pj"); repo=$(jq -r .repo <<<"$pj")

  now=$(date +%s)
  poll=$(jq -r '.poll_seconds // 600' <<<"$pj")
  last=$(state_get "$key")
  if [[ "$FORCE_SCAN" != 1 && -n "$last" && "$poll" -gt 0 ]] \
     && (( now - last < poll )); then
    log "$key not due (last scan ${last}, poll ${poll}s)"
    return 0
  fi

  days=$(jq -r '.triage_max_age_days // 30' <<<"$pj")
  max_age=$(( days * 86400 ))

  # ready-for-triage
  for row in $(api "$tok" "$API/repos/$repo/issues?state=open&labels=ready-for-triage&per_page=100" \
    | jq -r '.[] | select(.pull_request == null) | "\(.number)|\(.html_url)"'); do
    dispatch_triage "$pj" "$tok" "${row%%|*}" "${row#*|}" 0
  done

  # /fs-triage comments
  for row in $(api "$tok" "$API/repos/$repo/issues/comments?per_page=100&sort=created&direction=desc" \
    | jq -r '.[] | select(.body|test("^/fs-triage(\\s|$)")) | "\(.id)|\(.issue_url)"'); do
    cid="${row%%|*}"; issue_url="${row#*|}"; num="${issue_url##*/}"
    seen=$(api "$tok" "$API/repos/$repo/issues/comments/$cid/reactions" 2>/dev/null \
      | jq -r --arg me "$ME" '[.[]? | select(.user.login==$me and .content=="eyes")] | length')
    [[ "${seen:-0}" -gt 0 ]] && { log "$key comment $cid already dispatched"; continue; }
    dispatch_triage "$pj" "$tok" "$num" "https://github.com/$repo/issues/$num" 1
    [[ "$DRY_RUN" != 1 ]] && api_post "$tok" "$API/repos/$repo/issues/comments/$cid/reactions" -d '{"content":"eyes"}' >/dev/null 2>&1
  done

  # new issues
  for row in $(api "$tok" "$API/repos/$repo/issues?state=open&sort=created&direction=desc&per_page=50" \
    | jq -r --argjson age "$max_age" '
        .[]
        | select(.pull_request == null)
        | select((.labels | map(.name) | any(startswith("fullsend/triage-"))) | not)
        | select((.labels | map(.name) | any(startswith("fullsend/code-"))) | not)
        | select((.labels | map(.name) | any(. == "fullsend/tracking")) | not)
        | select((now - (.created_at | fromdateiso8601)) < $age)
        | "\(.number)|\(.html_url)"'); do
    dispatch_triage "$pj" "$tok" "${row%%|*}" "${row#*|}" 0
  done

  # ready-to-code
  local cdir; cdir=$(code_order_direction "$pj")
  for row in $(api "$tok" "$API/repos/$repo/issues?state=open&sort=created&direction=${cdir}&labels=ready-to-code&per_page=100" \
    | jq -r '.[] | select(.pull_request == null) | "\(.number)|\(.html_url)"'); do
    dispatch_code "$pj" "$tok" "${row%%|*}" "${row#*|}" ""
  done

  # /fs-code comments
  for row in $(api "$tok" "$API/repos/$repo/issues/comments?per_page=100&sort=created&direction=desc" \
    | jq -r '.[] | select(.body|test("^/fs-code(\\s|$)")) | "\(.id)|\(.issue_url)|\(.body|@base64)"'); do
    cid="${row%%|*}"; rest="${row#*|}"; issue_url="${rest%%|*}"; b64="${rest#*|}"
    body=$(printf '%s' "$b64" | base64 -d)
    num="${issue_url##*/}"
    seen=$(api "$tok" "$API/repos/$repo/issues/comments/$cid/reactions" 2>/dev/null \
      | jq -r --arg me "$ME" '[.[]? | select(.user.login==$me and .content=="eyes")] | length')
    [[ "${seen:-0}" -gt 0 ]] && { log "$key comment $cid already dispatched"; continue; }
    # Pass the whole comment: the pre-script reads the second token of the
    # first line, so `/fs-code --force` must arrive intact to bypass the
    # tracking-issue check.
    dispatch_code "$pj" "$tok" "$num" "https://github.com/$repo/issues/$num" "$body"
    [[ "$DRY_RUN" != 1 ]] && api_post "$tok" "$API/repos/$repo/issues/comments/$cid/reactions" -d '{"content":"eyes"}' >/dev/null 2>&1
  done

  state_set "$key" "$now"
}

# ------------------------------------------------------------------ main -----
# Test hook: source the script with DISPATCH_LIB_ONLY=1 to get the functions
# (job_manifest in particular) without touching the cluster or GitHub.
if [[ "${DISPATCH_LIB_ONLY:-0}" == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

k "$K8S/api/v1/namespaces/$NS/configmaps/$PROJECTS_CM" >"$TMP/cm.json" 2>/dev/null || true
jq -r '.data["projects.json"] // empty' "$TMP/cm.json" >"$TMP/projects.json" 2>/dev/null || true
jq -r '.data["models.json"] // empty' "$TMP/cm.json" >"$TMP/models.json" 2>/dev/null || true
[[ -s "$TMP/models.json" ]] || echo '{}' >"$TMP/models.json"
if ! jq -e 'type == "array" and length > 0' "$TMP/projects.json" >/dev/null 2>&1; then
  log "registry ConfigMap/$PROJECTS_CM key projects.json missing or not a non-empty array"
  exit 1
fi
if [[ "$MODE" == scan ]]; then
  validate_registry || exit 1
fi
log "projects=$(jq -r 'length' "$TMP/projects.json") models=$(jq -r 'length' "$TMP/models.json") mode=$MODE dry_run=$DRY_RUN"

# Resolve the authenticated identity once (for reaction markers).
first_inst=$(jq -r --arg d "$DEFAULT_INSTALLATION" '[.[]|select(.enabled // true)][0] | (.installation_id // $d) // empty' "$TMP/projects.json")
ME=""
if [[ -n "$first_inst" ]] && TOK=$(token_for "$first_inst"); then
  ME=$(curl -fsS -X POST "$API/graphql" -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" -d '{"query":"{viewer{login}}"}' 2>/dev/null | jq -r '.data.viewer.login // empty')
fi
[[ -n "$ME" ]] || { log "cannot resolve the authenticated identity"; exit 1; }
log "acting as $ME"

while IFS= read -r pj; do
  key=$(jq -r .key <<<"$pj"); repo=$(jq -r .repo <<<"$pj")
  inst=$(jq -r --arg d "$DEFAULT_INSTALLATION" '.installation_id // $d' <<<"$pj")
  [[ -n "$key" && -n "$repo" && -n "$inst" ]] || { log "skipping malformed project: $pj"; continue; }
  if ! TOK=$(token_for "$inst"); then
    log "$key: could not mint a token for installation $inst; skipping"
    continue
  fi
  if [[ "$MODE" == reconcile ]]; then
    log "$key ($repo) reconcile"
    reconcile_project "$pj" "$TOK"
  else
    log "$key ($repo) scan (poll=$(jq -r '.poll_seconds // 600' <<<"$pj")s)"
    scan_project "$pj" "$TOK"
  fi
done < <(jq -c '.[] | select(.enabled // true)' "$TMP/projects.json")

log "done"
