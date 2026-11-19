#!/usr/bin/env bash
# render-manifests.sh — substitute deployment values into k8s/*.tmpl.
#
# Reads values (environment > values.local.env > values.example.env) and writes
# k8s/rendered/<name>.yaml, which is what deploy scripts apply. Rendered output
# is git-ignored because it contains per-cluster identifiers.
set -euo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"

okd_require CLUSTER_DOMAIN NAMESPACE RUNNER_IMAGE OPENSHELL_GATEWAY_URL \
            KEYCLOAK_HOST KEYCLOAK_REALM OPENSHELL_OIDC_CLIENT_ID OPENSHELL_OIDC_ISSUER || exit 1

command -v envsubst >/dev/null || { echo "render: envsubst (gettext) is required" >&2; exit 1; }

# Only these variables are substituted; shell snippets inside the manifests use
# $VAR syntax of their own and must be left alone.
VARS='${NAMESPACE} ${INFERENCE_NAMESPACE} ${IMAGE_NAMESPACE} ${IN_CLUSTER_REGISTRY} ${RUNNER_IMAGE} ${CODE_IMAGE} ${SANDBOX_IMAGE} ${OPENSHELL_GATEWAY_URL} ${MODEL_API_BASE} ${GITHUB_APP_SECRET_NAME} ${PROBE_REPO} ${PROBE_ISSUE} ${OPENSHELL_OIDC_CLIENT_ID} ${OPENSHELL_OIDC_ISSUER} ${KEYCLOAK_HOST} ${KEYCLOAK_REALM} ${LITELLM_ROUTE} ${ENMAAS_API_BASE} ${FULLSEND_MAX_CONCURRENT_TRIAGE} ${FULLSEND_MAX_CONCURRENT_CODE}'

out="$OKD_ROOT/k8s/rendered"
mkdir -p "$out"
for t in "$OKD_ROOT"/k8s/*.tmpl; do
  [[ -e $t ]] || continue
  b=$(basename "$t" .tmpl)
  envsubst "$VARS" <"$t" >"$out/$b"
  echo "rendered k8s/rendered/$b"
done
