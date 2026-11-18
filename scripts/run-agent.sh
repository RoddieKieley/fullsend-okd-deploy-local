#!/usr/bin/env bash
# Run one fullsend agent inside the cluster.
#
# Forge selection is driven by FULLSEND_FORGE (github | forgejo). The harness
# overlay for the chosen forge supplies ISSUE_URL and the forge token for the
# pre/post scripts; this wrapper only clones the target repo and passes the
# flags through.
#
# Required env:
#   FULLSEND_FORGE        github (default) or forgejo
#   GH_TOKEN              github only
#   FORGEJO_URL, FORGEJO_USER, FORGEJO_TOKEN   forgejo only
#   KEYCLOAK_CLIENT_SECRET
# Optional env:
#   FULLSEND_AGENT        default: triage
#   FULLSEND_MODEL        default: ollama/Qwen3.8-27B
#   FULLSEND_REPO_SLUG    owner/repo (default: derived from the issue URL)
#   FULLSEND_RUN_POST     "1" to run the post-script (default: off)
set -uo pipefail

# GitHub App identity (preferred): mint a 1 h installation token and derive the
# bot user's noreply address. GIT_BOT_EMAIL feeds harness/code.yaml's
# GIT_AUTHOR_EMAIL/GIT_COMMITTER_EMAIL expansion, so a commit authored here is
# attributed to the App's bot user on GitHub. Falls back to the injected
# GH_TOKEN (PAT) when GITHUB_APP_ID is absent, e.g. ad-hoc run-*.sh Jobs.
if [[ -n "${GITHUB_APP_ID:-}" ]]; then
  GH_TOKEN=$(bash /scripts/mint-app-token.sh \
    "$GITHUB_APP_ID" \
    "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID must be set with GITHUB_APP_ID}" \
    "${GITHUB_APP_PRIVATE_KEY:-/var/run/secrets/github-app/private-key}") \
    || { echo "app installation token mint failed"; exit 12; }
  export GH_TOKEN
  # Installation tokens cannot call REST GET /user; GraphQL viewer resolves to
  # the bot user. databaseId is the *bot user* id used in the noreply address,
  # not the App id.
  viewer=$(curl -fsS -X POST https://api.github.com/graphql \
    -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: application/json" \
    -d '{"query":"{viewer{login databaseId}}"}' 2>/dev/null || true)
  bot_login=$(jq -r '.data.viewer.login // empty' <<<"${viewer:-}")
  bot_id=$(jq -r '.data.viewer.databaseId // empty' <<<"${viewer:-}")
  if [[ -n $bot_login && -n $bot_id ]]; then
    export GIT_BOT_EMAIL="${bot_id}+${bot_login}@users.noreply.github.com"
    echo "identity: ${bot_login} (${bot_id}) email=${GIT_BOT_EMAIL}"
  else
    echo "warning: could not resolve the App bot identity; commits stay unmapped"
  fi
  export PUSH_TOKEN_SOURCE=github-app
fi
export GIT_BOT_EMAIL="${GIT_BOT_EMAIL:-fullsend-code@users.noreply.github.com}"

# The gateway server cert is signed by the cluster's OpenShell CA, not a
# public CA. SSL_CERT_FILE replaces the trust store rather than adding to it,
# so build a bundle of the system CAs plus the gateway CA.
if [[ -r /etc/openshell-ca/ca.crt ]]; then
  bundle="${HOME:-/work}/ca-bundle.crt"
  cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/openshell-ca/ca.crt > "$bundle" 2>/dev/null \
    || cat /etc/ssl/certs/ca-certificates.crt /etc/openshell-ca/ca.crt > "$bundle" 2>/dev/null \
    || cp /etc/openshell-ca/ca.crt "$bundle"
  export SSL_CERT_FILE="$bundle"
fi

source /scripts/openshell-auth.sh
openshell_auth_init || { echo "gateway auth failed"; exit 10; }

FORGE="${FULLSEND_FORGE:-github}"
AGENT="${FULLSEND_AGENT:-triage}"
RUNTIME="${FULLSEND_RUNTIME:-opencode}"
MODEL="${FULLSEND_MODEL:-ollama/Qwen3.8-27B}"

case "$FORGE" in
  github)
    ISSUE_URL="${FULLSEND_ISSUE_URL:?FULLSEND_ISSUE_URL must be set}"
    SLUG="${FULLSEND_REPO_SLUG:-$(printf '%s' "$ISSUE_URL" | sed -n 's|^https://github.com/\([^/]*/[^/]*\)/.*|\1|p')}"
    [[ -n "$SLUG" ]] || { echo "cannot derive owner/repo from $ISSUE_URL"; exit 11; }
    [[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN must be set"; exit 11; }
    CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${SLUG}.git"
    export GITHUB_ISSUE_URL="$ISSUE_URL" FULLSEND_WORK_ITEM_URL="$ISSUE_URL"
    ;;
  forgejo)
    ISSUE_URL="${FORGEJO_ISSUE_URL:?FORGEJO_ISSUE_URL must be set}"
    : "${FORGEJO_URL:?FORGEJO_URL must be set}" "${FORGEJO_USER:?FORGEJO_USER must be set}" "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
    SLUG="${FULLSEND_REPO_SLUG:-$(printf '%s' "$ISSUE_URL" | sed -n "s|^${FORGEJO_URL%/}/\([^/]*/[^/]*\)/.*|\1|p")}"
    [[ -n "$SLUG" ]] || { echo "cannot derive owner/repo from $ISSUE_URL"; exit 11; }
    host="${FORGEJO_URL#*://}"; host="${host%%/*}"
    CLONE_URL="https://${FORGEJO_USER}:${FORGEJO_TOKEN}@${host}/${SLUG}.git"
    ;;
  *)
    echo "unsupported FULLSEND_FORGE=$FORGE (github|forgejo)"; exit 11 ;;
esac

echo "== forge=$FORGE agent=$AGENT runtime=$RUNTIME model=$MODEL repo=$SLUG issue=$ISSUE_URL =="

WORK=/work/repo
rm -rf "$WORK"; mkdir -p "$(dirname "$WORK")"
if ! git clone --depth 1 "$CLONE_URL" "$WORK"; then
  echo "clone failed for $SLUG"; exit 12
fi

export OPENCODE_CONFIG_CONTENT="$(cat /scripts/opencode-config.json)"

# Code-stage runner contract: pre-code/post-code read the push credential,
# repo identity and issue number from the runner environment, and the sandbox
# needs a git identity. Harmless for read-only agents.
NUM="${ISSUE_URL##*/}"
# The pre-code script compares REPO_FULL_NAME to the issue URL repo
# case-sensitively; GitHub's canonical html_url preserves owner case while a
# lowercase slug does not, so prefer the URL's form.
URL_REPO=$(printf '%s' "$ISSUE_URL" | sed -n 's|^https://[^/]*/\([^/]*/[^/]*\)/.*|\1|p')
export PUSH_TOKEN="${GH_TOKEN:-}"
export PUSH_TOKEN_SOURCE="${PUSH_TOKEN_SOURCE:-pat}"
export REPO_FULL_NAME="${URL_REPO:-$SLUG}"
export ISSUE_NUMBER="$NUM"
export TARGET_REPO_DIR="$WORK"
export GIT_BOT_EMAIL="${GIT_BOT_EMAIL:-fullsend-code@users.noreply.github.com}"

ARGS=(
  run "$AGENT"
  --fullsend-dir /harness
  --target-repo "$WORK"
  --forge "$FORGE"
  --runtime "$RUNTIME"
  --model "$MODEL"
  --output-dir /work/output
)
if [[ "${FULLSEND_RUN_POST:-0}" != "1" ]]; then
  ARGS+=(--no-post-script)
fi

mkdir -p /work/output
/usr/local/bin/fullsend "${ARGS[@]}"
rc=$?
echo "fullsend exit=$rc"
echo "== artifacts =="
find /work/output -maxdepth 2 -type f -printf '%p %s bytes\n' 2>/dev/null | head -40
exit "$rc"
