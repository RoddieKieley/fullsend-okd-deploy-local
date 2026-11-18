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

out="$OKD_ROOT/k8s/rendered"
mkdir -p "$out"
for t in "$OKD_ROOT"/k8s/*.tmpl; do
  [[ -e $t ]] || continue
  b=$(basename "$t" .tmpl)
  envsubst <"$t" >"$out/$b"
  echo "rendered k8s/rendered/$b"
done
