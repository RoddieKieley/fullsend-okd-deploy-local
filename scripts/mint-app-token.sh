#!/usr/bin/env bash
# mint-app-token.sh — print a GitHub App installation access token.
#
# GitHub Apps authenticate with a short-lived RS256 JWT (<= 10 minutes), signed
# with the App's private key, which is exchanged for an installation access
# token (fixed 1 hour). Only the installation token is printed, on stdout, so
# callers can do `TOKEN=$(mint-app-token.sh ...)`.
#
# Usage: mint-app-token.sh <app-id> <installation-id> <private-key.pem>
# Env:   GITHUB_API_URL  API base (default https://api.github.com)
# Needs: openssl, curl, jq
#
# Why openssl: the stock runner image has no python cryptography module, and an
# RS256 JWT needs RSA-SHA256 signing. The OKD image installs the openssl CLI
# (see image/Dockerfile).
set -euo pipefail

APP_ID=${1:?usage: mint-app-token.sh <app-id> <installation-id> <private-key.pem>}
INSTALL_ID=${2:?missing installation id}
KEY=${3:?missing private key path}
API=${GITHUB_API_URL:-https://api.github.com}

die() { echo "mint-app-token: $*" >&2; exit 1; }

[[ -r $KEY ]] || die "private key not readable: $KEY"
command -v openssl >/dev/null || die "openssl not found in the image"
command -v curl    >/dev/null || die "curl not found in the image"
command -v jq      >/dev/null || die "jq not found in the image"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
# iat is backdated 60s to tolerate clock skew; exp must stay <= 10 minutes.
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" \
  | openssl dgst -sha256 -sign "$KEY" -binary | b64url) \
  || die "could not sign the JWT with $KEY"
jwt="$header.$payload.$signature"

response=$(curl -sS -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  "$API/app/installations/$INSTALL_ID/access_tokens") \
  || die "POST /app/installations/$INSTALL_ID/access_tokens failed (transport)"

token=$(jq -r '.token // empty' <<<"$response")
if [[ -z $token ]]; then
  die "mint rejected: $(jq -r '.message // .' <<<"$response" | head -1)"
fi

printf '%s\n' "$token"
