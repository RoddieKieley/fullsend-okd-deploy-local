#!/usr/bin/env bash
# dispatch-manifest.sh — offline checks for the multi-project dispatcher.
#
# Sources dispatcher/dispatch.sh with DISPATCH_LIB_ONLY=1 (no cluster, no API
# calls) and asserts the Job manifest carries the project key, per-project
# deadline and model, and that the deadline is capped at the 1-hour token TTL.
set -uo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
D=$OKD_ROOT
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }

export OPENSHELL_GATEWAY_URL="https://example.invalid:8080"
export RUNNER_IMAGE="registry.example.invalid/ns/runner:test"
export KEYCLOAK_HOST="kc.example.invalid"
export KEYCLOAK_REALM="testrealm"
export OPENSHELL_OIDC_CLIENT_ID="test-client"
export OPENSHELL_OIDC_ISSUER="https://kc.example.invalid/realms/testrealm"
export GITHUB_APP_INSTALLATION_ID="REPLACE_WITH_INSTALLATION_ID"
export DISPATCH_LIB_ONLY=1
# shellcheck disable=SC1091
. "$D/dispatcher/dispatch.sh" scan >/dev/null 2>&1

# Model/locality fixture: job_manifest resolves locality from models.json.
printf '%s' '{"gateway/other":{"max_concurrent":2,"locality":"remote"},"ollama/other":{"max_concurrent":1,"locality":"local"}}' >"$TMP/models.json"

pj='{"key":"fs1","repo":"RoddieKieley/fs-scratch-1","installation_id":"REPLACE_WITH_INSTALLATION_ID",
      "poll_seconds":300,"deadline_seconds":9999,"max_code":1,
      "model_code":"gateway/other","model_triage":"ollama/other"}'

CODE=$(job_manifest "$pj" code 11 "https://github.com/RoddieKieley/fs-scratch-1/issues/11" "")
TRI=$(job_manifest "$pj" triage 11 "https://github.com/RoddieKieley/fs-scratch-1/issues/11" "")

j() { jq -r "$1" <<<"$2"; }

[[ $(j '.metadata.labels["fullsend/repo"]' "$CODE") == fs1 ]] \
  && ok "code job labelled fullsend/repo=fs1" || bad "missing fullsend/repo on code job"
[[ $(j '.spec.template.metadata.labels["fullsend/repo"]' "$CODE") == fs1 ]] \
  && ok "pod template labelled fullsend/repo=fs1" || bad "missing repo label on pod template"
[[ $(j '.metadata.labels["fullsend/issue"]' "$CODE") == 11 ]] \
  && ok "issue label preserved" || bad "issue label wrong"
[[ $(j '.spec.activeDeadlineSeconds' "$CODE") == 3300 ]] \
  && ok "code deadline capped at 3300 (token TTL)" || bad "code deadline not capped: $(j '.spec.activeDeadlineSeconds' "$CODE")"
[[ $(j '.spec.activeDeadlineSeconds' "$TRI") == 2400 ]] \
  && ok "triage deadline default 2400" || bad "triage deadline wrong"
[[ $(j '.metadata.generateName' "$CODE") == "fullsend-code-fs1-" ]] \
  && ok "job name is prefixed with the project key" || bad "generateName wrong: $(j '.metadata.generateName' "$CODE")"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="FULLSEND_MODEL")][0].value' "$CODE") == "gateway/other" ]] \
  && ok "per-project code model honoured" || bad "per-project code model ignored"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="FULLSEND_MODEL")][0].value' "$TRI") == "ollama/other" ]] \
  && ok "per-project triage model honoured" || bad "per-project triage model ignored"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="FULLSEND_REPO_KEY")][0].value' "$CODE") == fs1 ]] \
  && ok "FULLSEND_REPO_KEY passed to the runner" || bad "FULLSEND_REPO_KEY missing"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="GH_TOKEN")]|length' "$CODE") == 0 ]] \
  && ok "no PAT injected into the Job" || bad "GH_TOKEN still injected"
[[ $(j '.spec.template.spec.volumes[]|select(.name=="github-app")|.secret.secretName' "$CODE") == fullsend-github-app ]] \
  && ok "app private key mounted" || bad "app key not mounted"
MODEL_LABEL=$(j '.metadata.labels["fullsend/model"]' "$CODE")
[[ $MODEL_LABEL == gateway-other ]] \
  && ok "model label sanitised for Kubernetes (gateway/other -> gateway-other)" \
  || bad "model label wrong: $MODEL_LABEL"
[[ $(j '.metadata.labels["fullsend/model"]' "$TRI") == ollama-other ]] \
  && ok "triage model label applied" || bad "triage model label wrong"
[[ $(j '.metadata.labels["fullsend/locality"]' "$CODE") == remote ]] \
  && ok "code job labelled fullsend/locality=remote" || bad "code locality label wrong: $(j '.metadata.labels["fullsend/locality"]' "$CODE")"
[[ $(j '.metadata.labels["fullsend/locality"]' "$TRI") == local ]] \
  && ok "triage job labelled fullsend/locality=local" || bad "triage locality label wrong"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="KEYCLOAK_HOST")][0].value' "$CODE") == kc.example.invalid ]] \
  && ok "KEYCLOAK_HOST passed to the Job" || bad "KEYCLOAK_HOST missing from Job env"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="OPENSHELL_OIDC_CLIENT_ID")][0].value' "$CODE") == test-client ]] \
  && ok "OPENSHELL_OIDC_CLIENT_ID passed to the Job" || bad "OIDC client id missing from Job env"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="OPENSHELL_OIDC_ISSUER")][0].value' "$CODE") == https://kc.example.invalid/realms/testrealm ]] \
  && ok "OPENSHELL_OIDC_ISSUER passed to the Job" || bad "OIDC issuer missing from Job env"
[[ $(j '[.spec.template.spec.containers[0].env[]|select(.name=="FULLSEND_MODEL_LOCALITY")][0].value' "$CODE") == remote ]] \
  && ok "FULLSEND_MODEL_LOCALITY passed to the runner" || bad "FULLSEND_MODEL_LOCALITY missing"

[[ $(model_slug 'gateway/qwen38') == gateway-qwen38 ]] && ok "model_slug gateway/qwen38" || bad "model_slug gateway/qwen38"
[[ $(model_slug 'ollama/Qwen3.8-27B') == ollama-Qwen3.8-27B ]] && ok "model_slug keeps dots and case" || bad "model_slug ollama"

# force flag: only the second token of the first line counts (pre-script rule)
force_requested "/fs-code --force" && ok "force_requested: /fs-code --force" || bad "force not detected"
force_requested "/fs-code" && bad "plain /fs-code treated as force" || ok "force_requested: plain /fs-code is not force"
force_requested $'/fs-code do the thing --force' && bad "later --force treated as force" \
  || ok "force_requested: --force after the first token is ignored"
force_requested $'/fs-code --force\nplease also x' && ok "force_requested: first line only" \
  || bad "force on the first line not detected"
force_requested "" && bad "empty body treated as force" || ok "force_requested: empty body is not force"

# validate_registry: caps, declared locality, and privacy=local cannot use remote.
printf '%s' '{"gateway/other":{"max_concurrent":2,"locality":"remote"},"ollama/other":{"max_concurrent":1,"locality":"local"}}' >"$TMP/models.json"
printf '[{"key":"x","repo":"o/r","privacy":"any","model_code":"gateway/other","model_triage":"ollama/other"}]' >"$TMP/projects.json"
validate_registry >/dev/null 2>&1 && ok "registry accepted: capped, local+remote, privacy=any" \
  || bad "registry rejected a valid registry"

printf '[{"key":"x","repo":"o/r","privacy":"local","model_code":"gateway/other","model_triage":"ollama/other"}]' >"$TMP/projects.json"
validate_registry >/dev/null 2>&1 && bad "privacy=local accepted a remote model" \
  || ok "privacy=local rejects a remote model (fail closed)"

printf '[{"key":"x","repo":"o/r","privacy":"local","model_code":"ollama/other","model_triage":"ollama/other"}]' >"$TMP/projects.json"
validate_registry >/dev/null 2>&1 && ok "privacy=local accepted on all-local models" \
  || bad "privacy=local rejected an all-local registry"

printf '%s' '{"gateway/other":{"max_concurrent":2},"ollama/other":{"max_concurrent":1,"locality":"local"}}' >"$TMP/models.json"
printf '[{"key":"x","repo":"o/r","model_code":"gateway/other","model_triage":"ollama/other"}]' >"$TMP/projects.json"
validate_registry >/dev/null 2>&1 && bad "missing locality accepted" || ok "missing locality rejected"

printf '%s' '{"gateway/other":{"max_concurrent":2,"locality":"remote"}}' >"$TMP/models.json"
printf '[{"key":"x","repo":"o/r","model_code":"gateway/other","model_triage":"ollama/other"}]' >"$TMP/projects.json"
validate_registry >/dev/null 2>&1 && bad "uncapped/unknown model accepted" || ok "uncapped or unknown model rejected"

# sub_issue_count: GitHub native children. The stub only answers when the
# request carries a `variables` object, so this fails if the query regresses to
# positional/undefined variables.
api() {
  local body="${@: -1}"
  if [[ "$body" == *'"variables"'* ]]; then
    printf '%s' '{"data":{"repository":{"issue":{"subIssuesSummary":{"total":2}}}}}'
  else
    printf '%s' '{"errors":[{"message":"Variable $o of type String! was provided invalid value"}]}'
  fi
}
[[ $(sub_issue_count tok owner/repo 7) == 2 ]] && ok "sub_issue_count sends GraphQL variables" \
  || bad "sub_issue_count returned $(sub_issue_count tok owner/repo 7) (missing variables?)"
api() { printf '%s' '{"errors":[{"message":"Resource not accessible by integration"}]}'; }
[[ $(sub_issue_count tok owner/repo 7) == 0 ]] && ok "sub_issue_count degrades to 0 on an API error" \
  || bad "sub_issue_count did not degrade to 0"

# running_for_model: label (current) OR FULLSEND_MODEL env (legacy) counts, and
# finished jobs never count. `k` is stubbed so this stays offline.
k() {
  cat <<'JSON'
{"items":[
 {"metadata":{"labels":{"fullsend/model":"gateway-qwen38"}},
  "spec":{"template":{"spec":{"containers":[{"env":[{"name":"FULLSEND_MODEL","value":"gateway/qwen38"}]}]}}},
  "status":{"active":1}},
 {"metadata":{"labels":{}},
  "spec":{"template":{"spec":{"containers":[{"env":[{"name":"FULLSEND_MODEL","value":"gateway/qwen38"}]}]}}},
  "status":{"active":1}},
 {"metadata":{"labels":{"fullsend/model":"gateway-qwen38"}},
  "spec":{"template":{"spec":{"containers":[{"env":[]}]}}},
  "status":{"succeeded":1}},
 {"metadata":{"labels":{"fullsend/model":"ollama-qwen"}},
  "spec":{"template":{"spec":{"containers":[{"env":[]}]}}},
  "status":{"active":1}}
]}
JSON
}
[[ $(running_for_model 'gateway/qwen38') == 2 ]] \
  && ok "running_for_model counts label + legacy env, ignores finished and other models" \
  || bad "running_for_model returned $(running_for_model 'gateway/qwen38') (expected 2)"

# Registry fixture must stay valid JSON and carry both keys.
REG_FILE=$D/k8s/projects-config.yaml
[[ -f $REG_FILE ]] || REG_FILE=$D/k8s/projects-config.example.yaml
REG=$(sed -n '/projects.json: |/,/^---/p' "$REG_FILE" | sed '1d;/^---/d;s/^    //')
[[ $(jq -r 'length' <<<"$REG") -ge 1 ]] && ok "registry parses ($(jq -r 'length' <<<"$REG") projects)" || bad "registry invalid"
for k in $(jq -r '.[].key' <<<"$REG"); do
  [[ $k =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || bad "key '$k' is not a valid label value"
done
ok "registry keys are valid label values"

# code_order: scan_project must request the right direction from the issues API.
# `api` is stubbed to capture the requested URLs, so this stays offline.
CAP=$TMP/api-urls
: > "$CAP"
api() { printf '%s\n' "${2:-}" >> "$CAP"; printf '[]'; }
state_get() { printf ''; }
state_set() { :; }
dispatch_code() { :; }
ME=bot
scan_project '{"key":"x","repo":"o/r","code_order":"oldest"}' tok >/dev/null 2>&1
grep -q 'sort=created&direction=asc&labels=ready-to-code' "$CAP" \
  && ok "code_order=oldest requests direction=asc" \
  || bad "oldest order not requested: $(grep 'ready-to-code' "$CAP" | head -1)"
: > "$CAP"
scan_project '{"key":"x","repo":"o/r"}' tok >/dev/null 2>&1
grep -q 'sort=created&direction=desc&labels=ready-to-code' "$CAP" \
  && ok "default requests newest-first (direction=desc)" \
  || bad "default order not requested: $(grep 'ready-to-code' "$CAP" | head -1)"

printf '\n  passed: %d  failed: %d\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
